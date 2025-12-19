defmodule WawTrams.Queries.ActiveDelays do
  @moduledoc """
  Queries for real-time delay monitoring.

  Provides functions to retrieve currently active (unresolved) delays
  and recently resolved delays for dashboard visualization.
  """

  import Ecto.Query

  alias WawTrams.DelayEvent
  alias WawTrams.Repo

  @doc """
  Returns currently active (unresolved) delays.
  Ordered by most recent first.
  """
  def active do
    DelayEvent
    |> where([d], is_nil(d.resolved_at))
    |> order_by([d], desc: d.started_at)
    |> Repo.all()
  end

  @doc """
  Returns recent delay events for dashboard/visualization.
  Includes both active and resolved.
  """
  def recent(limit \\ 100) do
    DelayEvent
    |> order_by([d], desc: d.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Counts currently active (unresolved) delays.
  Used by Telemetry for metrics.
  """
  def count_active do
    DelayEvent
    |> where([d], is_nil(d.resolved_at))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts delays started today (UTC).
  Used by Telemetry for metrics.
  """
  def count_today do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    DelayEvent
    |> where([d], d.started_at >= ^today_start)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns recently resolved delays within a time period.
  """
  def resolved_since(since, limit \\ 20) do
    DelayEvent
    |> where([d], not is_nil(d.resolved_at) and d.resolved_at >= ^since)
    |> order_by([d], desc: d.resolved_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns recently resolved delays (most recent first).
  """
  def recent_resolved(limit \\ 20) do
    DelayEvent
    |> where([d], not is_nil(d.resolved_at))
    |> order_by([d], desc: d.resolved_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
