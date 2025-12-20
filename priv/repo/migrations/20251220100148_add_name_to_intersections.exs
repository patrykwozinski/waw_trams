defmodule WawTrams.Repo.Migrations.AddNameToIntersections do
  use Ecto.Migration

  def change do
    alter table(:intersections) do
      add :name, :string
    end
  end
end
