defmodule WawTrams.Repo.Migrations.CreateLineTerminals do
  use Ecto.Migration

  def change do
    create table(:line_terminals) do
      add :line, :string, null: false
      add :stop_id, :string, null: false
      add :terminal_name, :string
      # "start" or "end"
      add :direction, :string

      timestamps()
    end

    # Unique constraint: each (line, stop_id) pair appears once
    create unique_index(:line_terminals, [:line, :stop_id])

    # Index for lookups by line
    create index(:line_terminals, [:line])

    # Index for lookups by stop_id (for spatial joins)
    create index(:line_terminals, [:stop_id])
  end
end
