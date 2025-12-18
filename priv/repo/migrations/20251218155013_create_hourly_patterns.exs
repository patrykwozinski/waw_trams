defmodule WawTrams.Repo.Migrations.CreateHourlyPatterns do
  use Ecto.Migration

  def change do
    create table(:hourly_patterns) do
      # 1 (Monday) - 7 (Sunday)
      add :day_of_week, :integer, null: false
      # 0-23
      add :hour, :integer, null: false
      # Cumulative
      add :delay_count, :integer, default: 0
      add :blockage_count, :integer, default: 0
      add :total_seconds, :integer, default: 0

      timestamps()
    end

    create unique_index(:hourly_patterns, [:day_of_week, :hour])

    # Pre-populate with all 168 slots (7 days × 24 hours)
    execute """
            INSERT INTO hourly_patterns (day_of_week, hour, delay_count, blockage_count, total_seconds, inserted_at, updated_at)
            SELECT
              dow,
              h,
              0,
              0,
              0,
              NOW(),
              NOW()
            FROM generate_series(1, 7) AS dow
            CROSS JOIN generate_series(0, 23) AS h
            """,
            ""
  end
end
