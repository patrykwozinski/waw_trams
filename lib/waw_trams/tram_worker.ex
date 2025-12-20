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

  alias WawTrams.{Stop, Intersection, DelayEvent, LineTerminal}

  # Configuration
  @speed_threshold_kmh 3.0
  # 5 minutes without updates = terminate
  @idle_timeout_ms 5 * 60 * 1000

  # State struct
  defstruct [
    :vehicle_id,
    :line,
    :trip_id,
    positions: [],
    status: :unknown,
    stopped_since: nil,
    last_update: nil,
    # Delay tracking - persisted to DB
    delay_event_id: nil,
    delay_classification: nil,
    # Cached spatial query results (reset when tram moves)
    spatial_cache: nil
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

  @impl true
  def terminate(_reason, state) do
    # Resolve any active delay when worker terminates
    # This prevents orphaned delays when trams end service or disappear from feed
    if state.delay_event_id do
      case DelayEvent.get(state.delay_event_id) do
        nil ->
          :ok

        event ->
          if is_nil(event.resolved_at) do
            case DelayEvent.resolve(event) do
              {:ok, resolved} ->
                Logger.info(
                  "[TERMINATED] Vehicle #{state.vehicle_id} worker stopped, " <>
                    "resolved delay after #{resolved.duration_seconds}s"
                )

                Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_resolved, resolved})

              {:error, _} ->
                :ok
            end
          end
      end
    end

    :ok
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

  defp update_trip(state, %{trip_id: trip_id}) when is_binary(trip_id),
    do: %{state | trip_id: trip_id}

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
        # Vehicle is moving - resolve any active delay
        new_state = maybe_resolve_delay(state)

        %{
          new_state
          | status: :moving,
            stopped_since: nil,
            delay_event_id: nil,
            delay_classification: nil,
            spatial_cache: nil
        }
    end
  end

  defp maybe_resolve_delay(state) do
    if state.delay_event_id do
      case DelayEvent.get(state.delay_event_id) do
        nil ->
          state

        event ->
          if is_nil(event.resolved_at) do
            case DelayEvent.resolve(event) do
              {:ok, resolved} ->
                Logger.info(
                  "[RESOLVED] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
                    "moved after #{resolved.duration_seconds}s - was: #{resolved.classification}"
                )

                Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_resolved, resolved})

              {:error, reason} ->
                Logger.warning("Failed to resolve delay event: #{inspect(reason)}")
            end
          end

          state
      end
    else
      state
    end
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
      distance_km =
        haversine_distance(
          current.lat,
          current.lon,
          previous.lat,
          previous.lon
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

    a =
      :math.sin(delta_lat / 2) * :math.sin(delta_lat / 2) +
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
          # Use cached spatial results or compute them (once per stop location)
          {state, spatial} = get_or_compute_spatial(state, current_pos)

          if spatial.at_terminal do
            # Don't log delays at terminals - this is normal behavior
            state
          else
            classification = classify_delay(duration, spatial.at_stop)

            # New delay detected - persist to DB
            if should_persist?(classification) and is_nil(state.delay_event_id) do
              persist_new_delay(
                state,
                current_pos,
                classification,
                spatial.at_stop,
                spatial.near_intersection
              )
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

  # Get cached spatial data or compute it (single DB query batch per stop location)
  defp get_or_compute_spatial(%{spatial_cache: cache} = state, _pos) when not is_nil(cache) do
    # Cache hit - no DB calls
    {state, cache}
  end

  defp get_or_compute_spatial(state, pos) do
    # Cache miss - compute and store
    # These 3 queries happen only ONCE when tram first stops at a location
    at_terminal =
      state.line && LineTerminal.terminal_for_line?(state.line, pos.lat, pos.lon)

    at_stop = Stop.near_stop?(pos.lat, pos.lon, 50)
    near_intersection = Intersection.near_intersection?(pos.lat, pos.lon, 50)

    cache = %{
      at_terminal: at_terminal,
      at_stop: at_stop,
      near_intersection: near_intersection
    }

    {%{state | spatial_cache: cache}, cache}
  end

  defp persist_new_delay(state, pos, classification, at_stop, near_intersection) do
    # Use current time, not stopped_since - we only count ABNORMAL delay time
    # (time beyond the threshold that triggered the delay classification)
    # - "delay" triggers at 30s, so we count from 30s onward
    # - "blockage" triggers at 180s, so we count from 180s onward
    attrs = %{
      vehicle_id: state.vehicle_id,
      line: state.line,
      trip_id: state.trip_id,
      lat: pos.lat,
      lon: pos.lon,
      started_at: DateTime.utc_now(),
      classification: Atom.to_string(classification),
      at_stop: at_stop,
      near_intersection: near_intersection
    }

    case DelayEvent.create(attrs) do
      {:ok, event} ->
        # Look up intersection name for display in live tooltips
        location_name =
          if near_intersection do
            Intersection.nearest_name(pos.lat, pos.lon) || "Intersection"
          else
            nil
          end

        Logger.info(
          "[DELAY] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
            "stopped at #{location_name || "(#{Float.round(pos.lat, 4)}, #{Float.round(pos.lon, 4)})"} - " <>
            "#{classification}, at_stop: #{at_stop}, near_intersection: #{near_intersection}"
        )

        # Broadcast for live dashboard - include location_name for tooltips
        event_with_location = Map.put(event, :location_name, location_name)
        Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, event_with_location})
        %{state | delay_event_id: event.id, delay_classification: classification}

      {:error, reason} ->
        Logger.warning("Failed to persist delay event: #{inspect(reason)}")
        state
    end
  end

  @doc false
  # Exposed for testing - determines if a classification should be persisted
  def should_persist?(classification) do
    # Only persist actionable delays:
    # - :blockage (>180s at stop) - something is wrong
    # - :delay (>30s NOT at stop) - traffic/signal issue
    classification in [:blockage, :delay]
  end

  defp stopped_duration(%{stopped_since: nil}), do: 0

  defp stopped_duration(%{stopped_since: since}) do
    DateTime.diff(DateTime.utc_now(), since, :second)
  end

  @doc false
  # Exposed for testing - classifies a delay based on duration and location
  def classify_delay(duration, at_stop) do
    cond do
      # At stop: only flag if >3 minutes (real problem)
      at_stop and duration < 180 -> :normal_dwell
      at_stop -> :blockage
      # Not at stop: flag after 30s (traffic/signal issue)
      duration < 30 -> :brief_stop
      true -> :delay
    end
  end
end
