defmodule WawTrams.Repo.Migrations.AddMultiCycleToDelayEvents do
  use Ecto.Migration

  def change do
    alter table(:delay_events) do
      # True if delay > 120s (Warsaw signal cycle length)
      # Indicates tram missed multiple signal cycles = priority failure
      add :multi_cycle, :boolean, default: false
    end

    # Index for filtering/aggregating multi-cycle delays
    create index(:delay_events, [:multi_cycle], where: "multi_cycle = true")

    # Backfill existing resolved delays
    execute """
            UPDATE delay_events
            SET multi_cycle = true
            WHERE duration_seconds > 120
              AND resolved_at IS NOT NULL
            """,
            "SELECT 1"
  end
end
