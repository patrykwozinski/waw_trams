defmodule WawTrams.Repo.Migrations.CleanupRedundantIndexes do
  use Ecto.Migration

  @moduledoc """
  Removes unused and redundant indexes identified by pg_stat_user_indexes analysis.

  Indexes removed:
  - delay_events_classification_index: Redundant with delay_events_analytics_idx
  - stops_is_terminal_index: Never used (filter applied post-scan on spatial index)
  - hourly_intersection_stats_date_cost_pln_index: 0 scans
  - hourly_intersection_stats_lat_lon_index: 0 scans (unique index on date_hour_lat_lon is sufficient)
  - daily_intersection_stats_lat_lon_index: 0 scans
  - daily_line_stats_line_index: 0 scans
  """

  def up do
    # delay_events_classification_index is redundant - analytics_idx covers classification
    drop_if_exists index(:delay_events, [:classification])

    # stops_is_terminal_index never used - spatial queries filter after index scan
    drop_if_exists index(:stops, [:is_terminal])

    # hourly_intersection_stats indexes with 0 scans
    drop_if_exists index(:hourly_intersection_stats, [:date, :cost_pln])
    drop_if_exists index(:hourly_intersection_stats, [:lat, :lon])

    # daily_intersection_stats lat_lon index with 0 scans
    drop_if_exists index(:daily_intersection_stats, [:lat, :lon])

    # daily_line_stats line index with 0 scans
    drop_if_exists index(:daily_line_stats, [:line])
  end

  def down do
    # Recreate indexes if needed
    create_if_not_exists index(:delay_events, [:classification])
    create_if_not_exists index(:stops, [:is_terminal])
    create_if_not_exists index(:hourly_intersection_stats, [:date, :cost_pln])
    create_if_not_exists index(:hourly_intersection_stats, [:lat, :lon])
    create_if_not_exists index(:daily_intersection_stats, [:lat, :lon])
    create_if_not_exists index(:daily_line_stats, [:line])
  end
end
