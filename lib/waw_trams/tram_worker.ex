defmodule WawTrams.TramWorker do
  @moduledoc """
  GenServer process tracking state for a single tram.

  Each tram in the network gets its own worker process that:
  - Maintains position history
  - Calculates speed from position changes
  - Detects when vehicle is stopped (speed < threshold)
  - Tracks stop duration
  - Checks proximity to stops/intersections

  Workers are supervised by WawTrams.TramSupervisor and registered
  in WawTrams.TramRegistry for easy lookup by vehicle_id.
  """

  use GenServer
  require Logger

  alias WawTrams.{Stop, Intersection}

  # Configuration
  @speed_threshold_kmh 3.0
  @idle_timeout_ms 5 * 60 * 1000  # 5 minutes without updates = terminate

  # State struct
  defstruct [
    :vehicle_id,
    :line,
    :trip_id,
    positions: [],
    status: :unknown,
    stopped_since: nil,
    last_update: nil,
    # Delay tracking - to avoid duplicate logs
    delay_logged: false,
    delay_classification: nil
  ]

  # --- Client API ---

  def start_link(opts) do
    vehicle_id = Keyword.fetch!(opts, :vehicle_id)
    GenServer.start_link(__MODULE__, vehicle_id, name: via_tuple(vehicle_id))
  end

  @doc """
  Updates the worker with new position data from the feed.
  """
  def update(vehicle_id, position_data) do
    case WawTrams.TramSupervisor.whereis_worker(vehicle_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:update, position_data})
    end
  end

  @doc """
  Gets current state of a worker.
  """
  def get_state(vehicle_id) do
    case WawTrams.TramSupervisor.whereis_worker(vehicle_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_state)
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(vehicle_id) do
    Logger.debug("TramWorker started for vehicle #{vehicle_id}")
    schedule_idle_check()

    {:ok, %__MODULE__{vehicle_id: vehicle_id, last_update: DateTime.utc_now()}}
  end

  @impl true
  def handle_cast({:update, data}, state) do
    new_state =
      state
      |> update_position(data)
      |> update_line(data)
      |> update_trip(data)
      |> calculate_status()
      |> maybe_log_delay()

    {:noreply, %{new_state | last_update: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:idle_check, state) do
    if idle_too_long?(state) do
      Logger.debug("TramWorker #{state.vehicle_id} idle timeout, terminating")
      {:stop, :normal, state}
    else
      schedule_idle_check()
      {:noreply, state}
    end
  end

  # --- Private Functions ---

  defp via_tuple(vehicle_id) do
    {:via, Registry, {WawTrams.TramRegistry, vehicle_id}}
  end

  defp schedule_idle_check do
    Process.send_after(self(), :idle_check, @idle_timeout_ms)
  end

  defp idle_too_long?(state) do
    case state.last_update do
      nil -> false
      last -> DateTime.diff(DateTime.utc_now(), last, :millisecond) > @idle_timeout_ms
    end
  end

  defp update_position(state, %{lat: lat, lon: lon, timestamp: timestamp}) do
    position = %{
      lat: lat,
      lon: lon,
      timestamp: timestamp,
      recorded_at: DateTime.utc_now()
    }

    # Keep last 10 positions for speed calculation
    positions = Enum.take([position | state.positions], 10)

    %{state | positions: positions}
  end

  defp update_line(state, %{line: line}) when is_binary(line), do: %{state | line: line}
  defp update_line(state, _), do: state

  defp update_trip(state, %{trip_id: trip_id}) when is_binary(trip_id), do: %{state | trip_id: trip_id}
  defp update_trip(state, _), do: state

  defp calculate_status(state) do
    speed = calculate_speed(state.positions)

    cond do
      speed == nil ->
        %{state | status: :unknown}

      speed < @speed_threshold_kmh ->
        # Vehicle is stopped or very slow
        stopped_since = state.stopped_since || DateTime.utc_now()
        %{state | status: :stopped, stopped_since: stopped_since}

      true ->
        # Vehicle is moving - check if we need to log resolution
        new_state = maybe_log_delay_resolved(state)
        %{new_state | status: :moving, stopped_since: nil, delay_logged: false, delay_classification: nil}
    end
  end

  defp maybe_log_delay_resolved(state) do
    if state.delay_logged and state.stopped_since do
      duration = stopped_duration(state)
      current_pos = List.first(state.positions)

      if current_pos do
        Logger.info(
          "[RESOLVED] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
          "moved after #{duration}s stop at (#{Float.round(current_pos.lat, 4)}, #{Float.round(current_pos.lon, 4)}) - " <>
          "was: #{state.delay_classification}"
        )
      end
    end

    state
  end

  @doc false
  def calculate_speed(positions) when length(positions) < 2, do: nil

  def calculate_speed([current, previous | _]) do
    # Time difference in hours
    time_diff_seconds = DateTime.diff(current.timestamp, previous.timestamp, :second)

    if time_diff_seconds <= 0 do
      nil
    else
      time_diff_hours = time_diff_seconds / 3600

      # Distance using Haversine formula (in km)
      distance_km = haversine_distance(
        current.lat, current.lon,
        previous.lat, previous.lon
      )

      # Speed in km/h
      distance_km / time_diff_hours
    end
  end

  @doc """
  Haversine formula to calculate distance between two coordinates.
  Returns distance in kilometers.
  """
  def haversine_distance(lat1, lon1, lat2, lon2) do
    # Earth's radius in km
    r = 6371.0

    # Convert to radians
    lat1_rad = lat1 * :math.pi() / 180
    lat2_rad = lat2 * :math.pi() / 180
    delta_lat = (lat2 - lat1) * :math.pi() / 180
    delta_lon = (lon2 - lon1) * :math.pi() / 180

    a = :math.sin(delta_lat / 2) * :math.sin(delta_lat / 2) +
        :math.cos(lat1_rad) * :math.cos(lat2_rad) *
        :math.sin(delta_lon / 2) * :math.sin(delta_lon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    r * c
  end

  defp maybe_log_delay(state) do
    case state.status do
      :stopped ->
        duration = stopped_duration(state)
        current_pos = List.first(state.positions)

        if duration > 30 and current_pos do
          at_stop = Stop.near_stop?(current_pos.lat, current_pos.lon, 50)
          near_intersection = Intersection.near_intersection?(current_pos.lat, current_pos.lon, 50)

          classification = classify_delay(duration, at_stop)

          # Only log once when classification becomes loggable
          if should_log?(classification, duration, at_stop) and not already_logged?(state, classification) do
            Logger.info(
              "[DELAY] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
              "stopped for #{duration}s at (#{Float.round(current_pos.lat, 4)}, #{Float.round(current_pos.lon, 4)}) - " <>
              "at_stop: #{at_stop}, near_intersection: #{near_intersection}, " <>
              "classification: #{classification}"
            )

            %{state | delay_logged: true, delay_classification: classification}
          else
            # Update classification if it changed (escalated)
            if state.delay_logged and classification != state.delay_classification and should_log?(classification, duration, at_stop) do
              Logger.info(
                "[DELAY ESCALATED] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
                "now #{duration}s at (#{Float.round(current_pos.lat, 4)}, #{Float.round(current_pos.lon, 4)}) - " <>
                "#{state.delay_classification} -> #{classification}"
              )

              %{state | delay_classification: classification}
            else
              state
            end
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp already_logged?(state, _classification) do
    state.delay_logged
  end

  defp stopped_duration(%{stopped_since: nil}), do: 0
  defp stopped_duration(%{stopped_since: since}) do
    DateTime.diff(DateTime.utc_now(), since, :second)
  end

  defp classify_delay(duration, at_stop) do
    cond do
      at_stop and duration < 60 -> :normal_dwell
      at_stop and duration < 120 -> :extended_dwell
      at_stop -> :blockage
      duration < 60 -> :brief_stop
      true -> :delay
    end
  end

  defp should_log?(classification, duration, at_stop) do
    case classification do
      :normal_dwell -> false
      :brief_stop -> false
      :extended_dwell -> duration >= 60
      :blockage -> true
      :delay -> not at_stop and duration >= 30
    end
  end
end
