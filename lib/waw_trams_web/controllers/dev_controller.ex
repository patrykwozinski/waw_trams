defmodule WawTramsWeb.DevController do
  @moduledoc """
  Development-only controller for testing features.
  Only available when dev_routes is enabled.
  """
  use WawTramsWeb, :controller

  @intersections [
    {52.2297, 21.0122, "Centrum"},
    {52.2319, 20.9842, "Rondo Daszyńskiego"},
    {52.2215, 21.0060, "Politechnika"},
    {52.2388, 21.0453, "Rondo Wiatraczna"},
    {52.2553, 21.0350, "Dworzec Wileński"}
  ]

  def pulse(conn, _params) do
    # Pick a random intersection
    {lat, lon, name} = Enum.random(@intersections)

    # Create a fake delay event
    event = %{
      lat: lat,
      lon: lon,
      near_intersection: true,
      line: "#{Enum.random(1..35)}",
      vehicle_id: "test-#{:rand.uniform(1000)}"
    }

    # Broadcast to all connected AuditLive processes
    Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, event})

    json(conn, %{
      ok: true,
      message: "Pulsed at #{name}",
      lat: lat,
      lon: lon
    })
  end
end
