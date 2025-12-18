defmodule WawTrams.Repo.Migrations.CreateDelayEvents do
  use Ecto.Migration

  def change do
    create table(:delay_events) do
      add :vehicle_id, :string, null: false
      add :line, :string
      add :trip_id, :string

      # Location
      add :lat, :float, null: false
      add :lon, :float, null: false

      # Timing
      add :started_at, :utc_datetime_usec, null: false
      # null until tram moves
      add :resolved_at, :utc_datetime_usec
      # computed on resolution
      add :duration_seconds, :integer

      # Classification
      # blockage, delay
      add :classification, :string, null: false
      add :at_stop, :boolean, default: false
      add :near_intersection, :boolean, default: false

      timestamps()
    end

    create index(:delay_events, [:started_at])
    create index(:delay_events, [:classification])
    create index(:delay_events, [:line])
    create index(:delay_events, [:vehicle_id, :started_at])
    # For finding unresolved delays
    create index(:delay_events, [:vehicle_id],
             where: "resolved_at IS NULL",
             name: :delay_events_unresolved_idx
           )
  end
end
