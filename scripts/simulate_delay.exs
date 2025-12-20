# Simulate a delay event to test the real-time pulse animation
#
# Run with: mix run scripts/simulate_delay.exs
#
# Make sure the Phoenix server is running in another terminal!

# Sample Warsaw intersections to pulse at
intersections = [
  {52.2297, 21.0122, "Centrum"},  # Center
  {52.2319, 20.9842, "Rondo Daszyńskiego"},
  {52.2215, 21.0060, "Politechnika"},
  {52.2388, 21.0453, "Rondo Wiatraczna"},
  {52.2553, 21.0350, "Dworzec Wileński"},
]

IO.puts("\n🚋 Delay Pulse Simulator")
IO.puts("========================")
IO.puts("Open http://localhost:4000 in your browser to see the pulses!\n")

for {lat, lon, name} <- intersections do
  # Create a fake delay event
  event = %{
    lat: lat,
    lon: lon,
    near_intersection: true,
    line: "#{Enum.random(1..35)}",
    vehicle_id: "fake-#{:rand.uniform(1000)}"
  }

  IO.puts("📍 Pulsing at #{name} (#{lat}, #{lon})...")

  # Broadcast to all connected AuditLive processes
  Phoenix.PubSub.broadcast(WawTrams.PubSub, "delays", {:delay_created, event})

  # Wait 2 seconds between pulses
  Process.sleep(2000)
end

IO.puts("\n✅ Done! Did you see the pulses on the map?")
