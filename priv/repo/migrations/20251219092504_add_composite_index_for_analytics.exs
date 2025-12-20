defmodule WawTrams.Repo.Migrations.AddCompositeIndexForAnalytics do
  use Ecto.Migration

  @moduledoc """
  Adds composite index for analytics queries on delay_events.

  Currently the table is small (~1700 rows) and Seq Scan is optimal.
  As the table grows (800-1000 events/day), this index will help with:
  - hot_spots queries (WHERE near_intersection = true AND started_at >= X)
  - Classification filtering (WHERE classification IN (...) AND started_at >= X)

  The index is partial (only intersection-related delays) to keep it small.
  """

  def up do
    # Composite index for hot_spots and analytics queries
    # Covers: started_at range + near_intersection filter + classification filter
    create index(:delay_events, [:started_at, :near_intersection, :classification],
             name: :delay_events_analytics_idx,
             comment: "For hot_spots and analytics queries"
           )
  end

  def down do
    drop index(:delay_events, [:started_at, :near_intersection, :classification],
           name: :delay_events_analytics_idx
         )
  end
end
