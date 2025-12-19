defmodule WawTrams.Repo.Migrations.DropUnusedIndexes do
  use Ecto.Migration

  @moduledoc """
  Drops indexes that show 0 scans in pg_stat_user_indexes.

  Analyzed on 2024-12-19 with ~1700 delay_events:
  - daily_intersection_stats_date_index: 0 scans (covered by date_lat_lon_index)
  - daily_line_stats_date_index: 0 scans (covered by date_line_index)
  - line_terminals_line_index: 0 scans (queries use stop_id_index)

  Savings: ~48KB index space
  """

  def up do
    # These are redundant or unused based on query patterns
    drop_if_exists index(:daily_intersection_stats, [:date])
    drop_if_exists index(:daily_line_stats, [:date])
    drop_if_exists index(:line_terminals, [:line])
  end

  def down do
    # Recreate if needed
    create_if_not_exists index(:daily_intersection_stats, [:date])
    create_if_not_exists index(:daily_line_stats, [:date])
    create_if_not_exists index(:line_terminals, [:line])
  end
end
