defmodule WawTrams.Repo.Migrations.AddCoveringIndexes do
  use Ecto.Migration

  @doc """
  Adds covering indexes (INCLUDE clause) for index-only scans.

  This eliminates heap fetches for common query patterns by including
  frequently selected columns directly in the index.
  """
  def up do
    # Drop old indexes that will be replaced with covering versions
    drop_if_exists index(:delay_events, [:started_at], name: :delay_events_started_at_index)

    drop_if_exists index(:delay_events, [:started_at, :near_intersection, :classification],
                     name: :delay_events_analytics_idx
                   )

    drop_if_exists index(:delay_events, [:line], name: :delay_events_line_index)

    # 1. Main analytics index - covers 80% of queries
    # Filter: started_at range + near_intersection
    # Include: columns needed for aggregation without heap access
    execute """
    CREATE INDEX delay_events_analytics_covering_idx
    ON delay_events (started_at, near_intersection)
    INCLUDE (lat, lon, line, duration_seconds, classification, multi_cycle)
    """

    # 2. Line-specific queries (for line detail pages)
    # Filter: line + started_at range
    # Include: columns for line stats
    execute """
    CREATE INDEX delay_events_line_covering_idx
    ON delay_events (line, started_at)
    INCLUDE (lat, lon, duration_seconds, classification, near_intersection, multi_cycle)
    """

    # 3. Active delays - covering index for dashboard queries
    # Partial index for unresolved delays + commonly accessed columns
    execute """
    CREATE INDEX delay_events_active_covering_idx
    ON delay_events (vehicle_id)
    INCLUDE (lat, lon, line, started_at)
    WHERE resolved_at IS NULL
    """

    # Drop old unresolved index (replaced by covering version)
    drop_if_exists index(:delay_events, [:vehicle_id], name: :delay_events_unresolved_idx)

    # 4. Hourly stats - covering index for leaderboard queries
    # Note: the unique index already covers date/hour/lat/lon
    # This adds commonly selected aggregation columns
    execute """
    CREATE INDEX hourly_stats_covering_idx
    ON hourly_intersection_stats (date, hour)
    INCLUDE (lat, lon, delay_count, total_seconds, cost_pln, multi_cycle_count)
    """

    # 5. Daily line stats - covering index for dashboard
    # Note: cost is calculated from total_seconds, not stored
    execute """
    CREATE INDEX daily_line_stats_covering_idx
    ON daily_line_stats (date)
    INCLUDE (line, delay_count, total_seconds, blockage_count, intersection_count)
    """
  end

  def down do
    # Remove covering indexes
    execute "DROP INDEX IF EXISTS delay_events_analytics_covering_idx"
    execute "DROP INDEX IF EXISTS delay_events_line_covering_idx"
    execute "DROP INDEX IF EXISTS delay_events_active_covering_idx"
    execute "DROP INDEX IF EXISTS hourly_stats_covering_idx"
    execute "DROP INDEX IF EXISTS daily_line_stats_covering_idx"

    # Restore original indexes
    create index(:delay_events, [:started_at], name: :delay_events_started_at_index)

    create index(:delay_events, [:started_at, :near_intersection, :classification],
             name: :delay_events_analytics_idx
           )

    create index(:delay_events, [:line], name: :delay_events_line_index)

    create index(:delay_events, [:vehicle_id],
             name: :delay_events_unresolved_idx,
             where: "resolved_at IS NULL"
           )
  end
end
