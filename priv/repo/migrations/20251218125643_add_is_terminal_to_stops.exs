defmodule WawTrams.Repo.Migrations.AddIsTerminalToStops do
  use Ecto.Migration

  def change do
    alter table(:stops) do
      add :is_terminal, :boolean, default: false, null: false
    end

    create index(:stops, [:is_terminal])

    # Mark terminal stops based on Warsaw naming conventions
    # - "Pętla" = terminal loop
    # - "Zajezdnia" = depot
    # - "P+R" = Park & Ride (often terminals)
    execute """
    UPDATE stops SET is_terminal = true
    WHERE name ILIKE '%Pętla%'
       OR name ILIKE '%Zajezdnia%'
       OR name ILIKE '%P+R%'
    """, ""
  end
end
