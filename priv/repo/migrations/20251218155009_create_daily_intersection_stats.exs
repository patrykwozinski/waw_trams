defmodule WawTrams.Repo.Migrations.CreateDailyIntersectionStats do
  use Ecto.Migration

  def change do
    create table(:daily_intersection_stats) do
      add :date, :date, null: false
      # Rounded to 4 decimals (~11m precision)
      add :lat, :float, null: false
      # Rounded to 4 decimals
      add :lon, :float, null: false
      # Cached for display
      add :nearest_stop, :string
      add :delay_count, :integer, default: 0
      add :blockage_count, :integer, default: 0
      add :total_seconds, :integer, default: 0
      add :affected_lines, {:array, :string}, default: []

      timestamps()
    end

    create index(:daily_intersection_stats, [:date])
    create index(:daily_intersection_stats, [:lat, :lon])
    create unique_index(:daily_intersection_stats, [:date, :lat, :lon])
  end
end
