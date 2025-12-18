defmodule WawTrams.Repo.Migrations.CreateDailyLineStats do
  use Ecto.Migration

  def change do
    create table(:daily_line_stats) do
      add :date, :date, null: false
      add :line, :string, null: false
      add :delay_count, :integer, default: 0
      add :blockage_count, :integer, default: 0
      add :total_seconds, :integer, default: 0
      # Events near intersections
      add :intersection_count, :integer, default: 0
      # %{"6" => 3, "7" => 8, ...}
      add :by_hour, :map, default: %{}

      timestamps()
    end

    create index(:daily_line_stats, [:date])
    create index(:daily_line_stats, [:line])
    create unique_index(:daily_line_stats, [:date, :line])
  end
end
