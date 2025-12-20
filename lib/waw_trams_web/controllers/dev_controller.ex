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

  # Start a delay - shows live ticking bubble on map
  def delay_start(conn, _params) do
    {lat, lon, name} = Enum.random(@intersections)
    vehicle_id = "test-#{:rand.uniform(1000)}"
    line = "#{Enum.random(1..35)}"

    event = %{
      lat: lat,
      lon: lon,
      near_intersection: true,
      line: line,
      vehicle_id: vehicle_id
    }

    Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, event})

    json(conn, %{
      ok: true,
      message: "Delay started at #{name}",
      vehicle_id: vehicle_id,
      line: line,
      lat: lat,
      lon: lon
    })
  end

  # End a delay - shows explosion effect
  def delay_end(conn, %{"vehicle_id" => vehicle_id}) do
    {lat, lon, name} = Enum.random(@intersections)
    duration = Enum.random(45..300)

    event = %{
      lat: lat,
      lon: lon,
      near_intersection: true,
      line: "#{Enum.random(1..35)}",
      vehicle_id: vehicle_id,
      duration_seconds: duration
    }

    Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_resolved, event})

    json(conn, %{
      ok: true,
      message: "Delay ended at #{name}",
      vehicle_id: vehicle_id,
      duration: duration,
      lat: lat,
      lon: lon
    })
  end

  # Demo: Start a delay, wait, then resolve it with explosion
  def pulse(conn, _params) do
    {lat, lon, name} = Enum.random(@intersections)
    vehicle_id = "demo-#{:rand.uniform(1000)}"
    line = "#{Enum.random(1..35)}"

    # Start the delay
    start_event = %{
      lat: lat,
      lon: lon,
      near_intersection: true,
      line: line,
      vehicle_id: vehicle_id
    }

    Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, start_event})

    # Schedule the explosion after 5 seconds
    duration = Enum.random(45..180)

    spawn(fn ->
      Process.sleep(5_000)

      end_event = %{
        lat: lat,
        lon: lon,
        near_intersection: true,
        line: line,
        vehicle_id: vehicle_id,
        duration_seconds: duration
      }

      Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_resolved, end_event})
    end)

    json(conn, %{
      ok: true,
      message: "Demo started at #{name} - will explode in 5 seconds!",
      vehicle_id: vehicle_id,
      line: line,
      lat: lat,
      lon: lon
    })
  end
end
