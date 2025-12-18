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

  # Double-stop merge configuration
  # See guides/signal_timing.md for rationale
  @merge_distance_m 60
  @merge_grace_period_s 45

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
    # Avoids repeated DB calls while stopped at same location
    spatial_cache: nil,
    # Double-stop merge tracking
    # When set: {event_id, started_at, position, timestamp} - delay not yet finalized
    pending_resolution: nil
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

  defp update_trip(state, %{trip_id: trip_id}) when is_binary(trip_id),
    do: %{state | trip_id: trip_id}

  defp update_trip(state, _), do: state

  defp calculate_status(state) do
    speed = calculate_speed(state.positions)
    current_pos = List.first(state.positions)

    cond do
      speed == nil ->
        # Unknown speed - check for pending resolution timeout
        check_pending_resolution(state)

      speed < @speed_threshold_kmh ->
        # Vehicle is stopped or very slow
        handle_stopped(state, current_pos)

      true ->
        # Vehicle is moving
        handle_moving(state, current_pos)
    end
  end

  # Vehicle stopped - check if we should resume a pending delay
  defp handle_stopped(state, current_pos) do
    stopped_since = state.stopped_since || DateTime.utc_now()
    base_state = %{state | status: :stopped, stopped_since: stopped_since}

    case state.pending_resolution do
      {event_id, event_started_at, pending_pos, pending_time} when not is_nil(current_pos) ->
        # Check if this stop is close enough and soon enough to merge
        distance_m =
          haversine_distance(current_pos.lat, current_pos.lon, pending_pos.lat, pending_pos.lon) *
            1000

        time_since = DateTime.diff(DateTime.utc_now(), pending_time, :second)

        if distance_m <= @merge_distance_m and time_since <= @merge_grace_period_s do
          # Within merge window - cancel pending resolution, continue original delay
          Logger.debug(
            "[MERGE] Vehicle #{state.vehicle_id} stopped again within #{round(distance_m)}m, " <>
              "#{time_since}s - continuing original delay"
          )

          %{
            base_state
            | delay_event_id: event_id,
              pending_resolution: nil,
              # Use cached started_at from pending - no DB call needed
              stopped_since: event_started_at || stopped_since,
              # Clear spatial cache since we're resuming a different context
              spatial_cache: nil
          }
        else
          # Outside merge window - finalize pending, start fresh
          finalize_pending_resolution(state)
          %{base_state | pending_resolution: nil, spatial_cache: nil}
        end

      _ ->
        # No pending resolution, normal stop
        base_state
    end
  end

  # Vehicle moving - set pending resolution instead of immediate resolve
  defp handle_moving(state, current_pos) do
    base_state = %{
      state
      | status: :moving,
        stopped_since: nil,
        # Clear spatial cache when moving - will recalculate on next stop
        spatial_cache: nil
    }

    cond do
      # Active delay that needs pending resolution
      state.delay_event_id && is_nil(state.pending_resolution) && current_pos ->
        Logger.debug(
          "[PENDING] Vehicle #{state.vehicle_id} moving - delay resolution pending for #{@merge_grace_period_s}s"
        )

        # Include stopped_since in tuple to avoid DB lookup later
        %{
          base_state
          | pending_resolution:
              {state.delay_event_id, state.stopped_since, current_pos, DateTime.utc_now()},
            delay_event_id: nil,
            delay_classification: nil
        }

      # Already has pending resolution - check if should finalize
      state.pending_resolution ->
        check_pending_resolution(base_state)

      # No active delay
      true ->
        base_state
    end
  end

  # Check and potentially finalize a pending resolution
  defp check_pending_resolution(%{pending_resolution: nil} = state), do: state

  defp check_pending_resolution(
         %{pending_resolution: {_event_id, _started_at, _pos, pending_time}} = state
       ) do
    time_since = DateTime.diff(DateTime.utc_now(), pending_time, :second)

    if time_since > @merge_grace_period_s do
      finalize_pending_resolution(state)
    else
      state
    end
  end

  # Finalize a pending resolution - actually resolve the delay in DB
  defp finalize_pending_resolution(%{pending_resolution: nil} = state), do: state

  defp finalize_pending_resolution(
         %{pending_resolution: {event_id, _started_at, _pos, _time}} = state
       ) do
    # Single DB call to get and resolve
    case DelayEvent.get(event_id) do
      nil ->
        %{state | pending_resolution: nil}

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

        %{state | pending_resolution: nil}
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
    attrs = %{
      vehicle_id: state.vehicle_id,
      line: state.line,
      trip_id: state.trip_id,
      lat: pos.lat,
      lon: pos.lon,
      started_at: state.stopped_since,
      classification: Atom.to_string(classification),
      at_stop: at_stop,
      near_intersection: near_intersection
    }

    case DelayEvent.create(attrs) do
      {:ok, event} ->
        Logger.info(
          "[DELAY] Vehicle #{state.vehicle_id} (Line #{state.line}) " <>
            "stopped at (#{Float.round(pos.lat, 4)}, #{Float.round(pos.lon, 4)}) - " <>
            "#{classification}, at_stop: #{at_stop}, near_intersection: #{near_intersection}"
        )

        # Broadcast for live dashboard
        Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, event})
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
