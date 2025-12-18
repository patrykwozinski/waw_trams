defmodule WawTrams.Poller do
  @moduledoc """
  GenServer that polls the GTFS-Realtime vehicle positions feed.

  Fetches from mkuran.pl every 10 seconds, decodes the protobuf,
  filters for trams, and dispatches position updates to TramWorkers.

  ## Data Source

  - URL: https://mkuran.pl/gtfs/warsaw/vehicles.pb
  - Format: GTFS-Realtime Protocol Buffer
  - Source: Warsaw City Hall (via mkuran.pl)
  """

  use GenServer
  require Logger

  @feed_url "https://mkuran.pl/gtfs/warsaw/vehicles.pb"
  @poll_interval_ms 10_000

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns current polling stats.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Forces an immediate poll (for testing).
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("Poller starting, will fetch from #{@feed_url}")

    state = %{
      last_poll: nil,
      last_vehicle_count: 0,
      last_tram_count: 0,
      total_polls: 0,
      errors: 0
    }

    # Start polling after a short delay to let other processes start
    Process.send_after(self(), :poll, 1_000)

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    schedule_next_poll()
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    new_state = do_poll(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state, state}
  end

  # --- Private Functions ---

  defp schedule_next_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp do_poll(state) do
    case fetch_and_process() do
      {:ok, vehicle_count, tram_count} ->
        %{
          state
          | last_poll: DateTime.utc_now(),
            last_vehicle_count: vehicle_count,
            last_tram_count: tram_count,
            total_polls: state.total_polls + 1
        }

      {:error, reason} ->
        Logger.error("Poller fetch failed: #{inspect(reason)}")
        %{state | errors: state.errors + 1}
    end
  end

  defp fetch_and_process do
    with {:ok, body} <- fetch_feed(),
         {:ok, feed} <- decode_feed(body),
         {:ok, vehicles} <- extract_vehicles(feed) do
      trams = filter_trams(vehicles)

      Logger.debug("Polled #{length(vehicles)} vehicles, #{length(trams)} trams")

      dispatch_to_workers(trams)

      {:ok, length(vehicles), length(trams)}
    end
  end

  defp fetch_feed do
    case Req.get(@feed_url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_feed(body) do
    try do
      feed = TransitRealtime.FeedMessage.decode(body)
      {:ok, feed}
    rescue
      e -> {:error, {:decode_error, e}}
    end
  end

  defp extract_vehicles(feed) do
    vehicles =
      feed.entity
      |> Enum.filter(& &1.vehicle)
      |> Enum.map(& &1.vehicle)

    {:ok, vehicles}
  end

  defp filter_trams(vehicles) do
    # Filter for trams based on vehicle.id pattern
    # Warsaw format: vehicle.id = "V/{line}/{brigade}"
    # Tram lines are 1-79, bus lines are 100+
    Enum.filter(vehicles, fn vehicle ->
      line = extract_line_number(vehicle)
      is_tram_line?(line)
    end)
  end

  defp extract_line_number(vehicle) do
    # Try to extract line from vehicle.id (format: "V/{line}/{brigade}")
    case vehicle.vehicle && vehicle.vehicle.id do
      "V/" <> rest ->
        case String.split(rest, "/") do
          [line | _] -> line
          _ -> nil
        end

      _ ->
        # Fallback: try trip_id (format: "date:line:...")
        case vehicle.trip && vehicle.trip.trip_id do
          nil ->
            nil

          trip_id ->
            case String.split(trip_id, ":") do
              [_date, line | _] -> line
              _ -> nil
            end
        end
    end
  end

  @doc false
  # Exposed for testing
  def is_tram_line?(nil), do: false

  def is_tram_line?(line) do
    # Warsaw tram lines are 1-79
    # Bus lines are 100+, night buses N*, etc.
    case Integer.parse(line) do
      {num, ""} when num >= 1 and num <= 79 -> true
      _ -> false
    end
  end

  defp dispatch_to_workers(trams) do
    for vehicle <- trams do
      vehicle_id = extract_vehicle_id(vehicle)

      if vehicle_id do
        # Start worker if not exists
        case WawTrams.TramSupervisor.start_worker(vehicle_id) do
          {:ok, _pid} ->
            position_data = extract_position_data(vehicle)
            WawTrams.TramWorker.update(vehicle_id, position_data)

          {:error, {:already_started, _pid}} ->
            position_data = extract_position_data(vehicle)
            WawTrams.TramWorker.update(vehicle_id, position_data)

          {:error, reason} ->
            Logger.warning("Failed to start worker for #{vehicle_id}: #{inspect(reason)}")
        end
      end
    end
  end

  defp extract_vehicle_id(vehicle) do
    # Try vehicle.id first, then vehicle.label
    cond do
      vehicle.vehicle && vehicle.vehicle.id -> vehicle.vehicle.id
      vehicle.vehicle && vehicle.vehicle.label -> vehicle.vehicle.label
      true -> nil
    end
  end

  defp extract_position_data(vehicle) do
    pos = vehicle.position
    trip = vehicle.trip
    line = extract_line_number(vehicle)

    timestamp =
      if vehicle.timestamp do
        DateTime.from_unix!(vehicle.timestamp)
      else
        DateTime.utc_now()
      end

    %{
      lat: pos && pos.latitude,
      lon: pos && pos.longitude,
      bearing: pos && pos.bearing,
      speed: pos && pos.speed,
      timestamp: timestamp,
      line: line,
      trip_id: trip && trip.trip_id
    }
  end
end
