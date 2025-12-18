defmodule WawTrams.Repo.Migrations.DropRedundantDelayEventsIndex do
  use Ecto.Migration

  def change do
    # This compound index is redundant because:
    # - find_unresolved() uses WHERE vehicle_id = X AND resolved_at IS NULL
    # - The partial index (unresolved_idx) already covers this use case efficiently
    drop index(:delay_events, [:vehicle_id, :started_at])
  end
end
