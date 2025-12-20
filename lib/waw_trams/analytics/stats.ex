defmodule WawTrams.Analytics.Stats do
  @moduledoc """
  Aggregated statistics for delay events.

  Provides classification breakdowns, multi-cycle counts,
  and time-based aggregations.
  """

  import Ecto.Query

  alias WawTrams.DelayEvent
  alias WawTrams.Repo

  @doc """
  Returns delay statistics for a time period.

  Groups by classification and returns count + average duration.

  ## Example

      iex> Stats.for_period(DateTime.add(DateTime.utc_now(), -24, :hour))
      [
        %{classification: "delay", count: 150, avg_duration_seconds: 45.2},
        %{classification: "blockage", count: 23, avg_duration_seconds: 210.5}
      ]
  """
  def for_period(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    query =
      from d in DelayEvent,
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

  @doc """
  Returns count of multi-cycle delays (priority failures) in a time period.

  Multi-cycle means delay > 120s (Warsaw signal cycle), indicating the
  tram missed multiple green phases due to broken priority.

  Only counts delays at intersections - priority failures can only happen
  where there are traffic signals.
  """
  def multi_cycle_count(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    from(d in DelayEvent,
      where: d.started_at >= ^since and d.multi_cycle == true and d.near_intersection == true,
      select: count(d.id)
    )
    |> Repo.one()
  end

  @doc """
  Returns total time lost to delays in a period (in seconds).
  """
  def total_time_lost(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    from(d in DelayEvent,
      where: d.started_at >= ^since and not is_nil(d.duration_seconds),
      select: sum(d.duration_seconds)
    )
    |> Repo.one() || 0
  end

  @doc """
  Returns a summary of all key stats for a period.
  Useful for dashboard headers.
  """
  def summary(since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    stats = for_period(since)

    delay_stats =
      Enum.find(stats, %{count: 0, avg_duration_seconds: 0}, &(&1.classification == "delay"))

    blockage_stats =
      Enum.find(stats, %{count: 0, avg_duration_seconds: 0}, &(&1.classification == "blockage"))

    total_seconds = total_time_lost(since)
    multi_cycle = multi_cycle_count(since)

    %{
      delay_count: delay_stats.count,
      blockage_count: blockage_stats.count,
      total_count: delay_stats.count + blockage_stats.count,
      total_seconds: total_seconds,
      total_hours: Float.round(total_seconds / 3600, 1),
      multi_cycle_count: multi_cycle,
      avg_delay_seconds: delay_stats.avg_duration_seconds || 0,
      avg_blockage_seconds: blockage_stats.avg_duration_seconds || 0
    }
  end
end
