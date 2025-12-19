defmodule WawTrams.Repo.Migrations.CreateHourlyIntersectionStats do
  use Ecto.Migration

  def change do
    create table(:hourly_intersection_stats) do
      # Time bucket
      add :date, :date, null: false
      add :hour, :integer, null: false

      # Location (cluster centroid, rounded to 4 decimals ~11m precision)
      add :lat, :float, null: false
      add :lon, :float, null: false

      # Stats
      add :delay_count, :integer, default: 0
      add :multi_cycle_count, :integer, default: 0
      add :total_seconds, :integer, default: 0

      # Pre-calculated cost (uses hour for passenger estimate)
      add :cost_pln, :float, default: 0.0

      # Affected lines (for filtering)
      add :lines, {:array, :string}, default: []

      timestamps()
    end

    # Primary lookup: date + hour + location
    create unique_index(:hourly_intersection_stats, [:date, :hour, :lat, :lon])

    # For leaderboard queries (top by cost)
    create index(:hourly_intersection_stats, [:date, :cost_pln])

    # For location-based queries
    create index(:hourly_intersection_stats, [:lat, :lon])
  end
end
