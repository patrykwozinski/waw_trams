defmodule WawTrams.Repo do
  use Ecto.Repo,
    otp_app: :waw_trams,
    adapter: Ecto.Adapters.Postgres
end
