defmodule WawTrams.DelayEvent do
  @moduledoc """
  Schema for delay events detected by TramWorkers.

  Only actionable delays are persisted:
  - `blockage`: >180s at a stop (potential incident, not normal boarding)
  - `delay`: >30s NOT at a stop (traffic/signal issue - the gold!)

  Normal dwell times (<180s at stops) and brief stops (<30s) are not stored.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WawTrams.Repo

  schema "delay_events" do
    field :vehicle_id, :string
    field :line, :string
    field :trip_id, :string

    # Location
    field :lat, :float
    field :lon, :float

    # Timing
    field :started_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :duration_seconds, :integer

    # Classification
    field :classification, :string
    field :at_stop, :boolean, default: false
    field :near_intersection, :boolean, default: false
    # True if delay > 120s (Warsaw signal cycle) = priority system failure
    field :multi_cycle, :boolean, default: false

    timestamps()
  end

  # Warsaw signal cycle length in seconds
  @signal_cycle_seconds 120
  # Additional buffer for boarding when stop is near intersection
  @boarding_buffer_seconds 60

  @required_fields ~w(vehicle_id lat lon started_at classification)a
  @optional_fields ~w(line trip_id resolved_at duration_seconds at_stop near_intersection multi_cycle)a

  def changeset(delay_event, attrs) do
    delay_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:classification, ~w(blockage delay))
  end

  @doc """
  Creates a new delay event when a delay is first detected.
  """
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a delay event by ID.
  """
  def get(id), do: Repo.get(__MODULE__, id)

  @doc """
  Finds an unresolved delay event for a vehicle.
  """
  def find_unresolved(vehicle_id) do
    __MODULE__
    |> where([d], d.vehicle_id == ^vehicle_id and is_nil(d.resolved_at))
    |> order_by([d], desc: d.started_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Resolves a delay event when the tram starts moving again.

  Sets `multi_cycle: true` if duration exceeds the appropriate threshold:
  - Intersection only: 120s (one signal cycle)
  - Stop + Intersection: 180s (cycle + 60s boarding buffer)

  This flags signal priority failures specifically - delays where the tram
  waited through multiple signal cycles because the priority system failed.
  The boarding buffer accounts for normal dwell time at stops near intersections.
  """
  def resolve(%__MODULE__{} = event) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, event.started_at, :second)

    # Multi-cycle threshold depends on whether tram is also at a stop
    # Stop + intersection: add boarding buffer (60s) to account for normal dwell
    threshold =
      if event.at_stop and event.near_intersection do
        @signal_cycle_seconds + @boarding_buffer_seconds
      else
        @signal_cycle_seconds
      end

    # Multi-cycle only applies to intersection delays (priority failures)
    multi_cycle = event.near_intersection and duration > threshold

    event
    |> changeset(%{resolved_at: now, duration_seconds: duration, multi_cycle: multi_cycle})
    |> Repo.update()
  end

  @doc """
  Deletes all orphaned delay events (unresolved delays from previous server runs).

  Called on application startup to clean up hanging delays that would never
  be resolved because their TramWorker processes no longer exist.

  We delete rather than resolve because:
  - We don't know when the tram actually moved
  - Server downtime would create artificially long durations
  - This would skew analytics (avg delay, total time lost)
  """
  def cleanup_orphaned do
    {count, _} =
      from(d in __MODULE__, where: is_nil(d.resolved_at))
      |> Repo.delete_all()

    if count > 0 do
      require Logger
      Logger.info("[STARTUP] Deleted #{count} orphaned delay events from previous run")
    end

    {:ok, count}
  end
end
