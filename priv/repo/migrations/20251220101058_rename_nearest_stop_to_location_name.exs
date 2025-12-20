defmodule WawTrams.Repo.Migrations.RenameNearestStopToLocationName do
  use Ecto.Migration

  def change do
    rename table(:daily_intersection_stats), :nearest_stop, to: :location_name
  end
end
