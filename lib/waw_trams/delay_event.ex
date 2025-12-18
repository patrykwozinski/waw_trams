defmodule WawTrams.DelayEvent do
  @moduledoc """
  Schema for delay events detected by TramWorkers.

  Only significant delays are persisted:
  - `extended_dwell`: >60s at a stop (unusual passenger boarding)
  - `blockage`: >120s at a stop (potential incident)
  - `delay`: >30s NOT at a stop (traffic/signal issue)

  Normal dwell times (<60s at stops) and brief stops (<30s) are not stored.
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

    timestamps()
  end

  @required_fields ~w(vehicle_id lat lon started_at classification)a
  @optional_fields ~w(line trip_id resolved_at duration_seconds at_stop near_intersection)a

  def changeset(delay_event, attrs) do
    delay_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:classification, ~w(extended_dwell blockage delay))
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
  """
  def resolve(%__MODULE__{} = event) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, event.started_at, :second)

    event
    |> changeset(%{resolved_at: now, duration_seconds: duration})
    |> Repo.update()
  end

  @doc """
  Updates classification if delay escalates (e.g., extended_dwell -> blockage).
  """
  def escalate(%__MODULE__{} = event, new_classification) do
    event
    |> changeset(%{classification: new_classification})
    |> Repo.update()
  end

  @doc """
  Returns recent delay events for dashboard/visualization.
  """
  def recent(limit \\ 100) do
    __MODULE__
    |> order_by([d], desc: d.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns currently active (unresolved) delays.
  """
  def active do
    __MODULE__
    |> where([d], is_nil(d.resolved_at))
    |> order_by([d], desc: d.started_at)
    |> Repo.all()
  end

  @doc """
  Returns delay statistics for a time period.
  """
  def stats(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    query =
      from d in __MODULE__,
        where: d.started_at >= ^since,
        group_by: d.classification,
        select: {d.classification, count(d.id), avg(d.duration_seconds)}

    query
    |> Repo.all()
    |> Enum.map(fn {classification, count, avg_duration} ->
      %{
        classification: classification,
        count: count,
        avg_duration_seconds: avg_duration && Decimal.to_float(avg_duration)
      }
    end)
  end
end
