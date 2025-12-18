defmodule WawTramsWeb.DashboardLive do
  use WawTramsWeb, :live_view

  alias WawTrams.DelayEvent

  # 5 seconds
  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to delay updates
      Phoenix.PubSub.subscribe(WawTrams.PubSub, "delays")
      # Schedule periodic refresh
      schedule_refresh()
    end

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_info({:delay_created, _delay}, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_info({:delay_resolved, _delay}, socket) do
    {:noreply, assign_data(socket)}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp assign_data(socket) do
    active_delays = DelayEvent.active()
    recent_resolved = get_recent_resolved(20)
    stats = DelayEvent.stats()
    hot_spots = DelayEvent.hot_spots(limit: 10)
    hot_spot_summary = DelayEvent.hot_spot_summary()
    impacted_lines = DelayEvent.impacted_lines(limit: 10)

    socket
    |> assign(:active_delays, active_delays)
    |> assign(:active_count, length(active_delays))
    |> assign(:recent_resolved, recent_resolved)
    |> assign(:stats, stats)
    |> assign(:hot_spots, hot_spots)
    |> assign(:hot_spot_summary, hot_spot_summary)
    |> assign(:impacted_lines, impacted_lines)
    |> assign(:last_updated, DateTime.utc_now())
  end

  defp get_recent_resolved(limit) do
    import Ecto.Query

    DelayEvent
    |> where([d], not is_nil(d.resolved_at))
    |> order_by([d], desc: d.resolved_at)
    |> limit(^limit)
    |> WawTrams.Repo.all()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-[1600px] mx-auto px-6 py-8">
        <%!-- Header --%>
        <div class="mb-8 flex flex-wrap items-start justify-between gap-6">
          <div>
            <h1 class="text-3xl font-bold text-amber-400 tracking-tight">
              🚋 Warsaw Tram Delays
            </h1>
            <p class="text-gray-400 mt-1">
              Real-time delay monitoring • Updated {format_time(@last_updated)}
            </p>
          </div>

          <div class="flex flex-col items-end gap-3">
            <%!-- Navigation --%>
            <div class="flex gap-2">
              <.link
                navigate={~p"/map"}
                class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm transition-colors"
              >
                🗺️ Map
              </.link>
              <.link
                navigate={~p"/heatmap"}
                class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm transition-colors"
              >
                📊 Heatmap
              </.link>
              <.link
                navigate={~p"/line"}
                class="px-3 py-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg text-sm transition-colors"
              >
                🚋 By Line
              </.link>
            </div>

            <%!-- Legend --%>
            <div class="bg-gray-900/50 rounded-lg px-4 py-3 border border-gray-800 text-sm">
              <div class="text-gray-400 font-medium mb-2">Classification Legend</div>
              <div class="flex flex-wrap gap-x-6 gap-y-1">
                <div class="flex items-center gap-2">
                  <span class="px-2 py-0.5 rounded text-xs font-medium bg-orange-500/20 text-orange-400">
                    delay
                  </span>
                  <span class="text-gray-500">30s – 3min stop</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/20 text-red-400">
                    blockage
                  </span>
                  <span class="text-gray-500">> 3min stop</span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="text-orange-400">⚠️</span>
                  <span class="text-gray-500">near traffic signal</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Stats Cards --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-orange-400">
              {@hot_spot_summary.intersection_count}
            </div>
            <div class="text-gray-400 text-sm mt-1">Problem Intersections</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-amber-400">
              {@hot_spot_summary.total_delay_minutes}
            </div>
            <div class="text-gray-400 text-sm mt-1">Minutes Lost (24h)</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-red-400">{@active_count}</div>
            <div class="text-gray-400 text-sm mt-1">Active Now</div>
          </div>
          <%= for stat <- @stats do %>
            <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
              <div class="text-4xl font-bold text-gray-300">{stat.count}</div>
              <div class="text-gray-400 text-sm mt-1">
                {String.capitalize(stat.classification)} (24h)
              </div>
            </div>
          <% end %>
        </div>

        <%!-- KEY INSIGHTS: Hot Spots + Most Impacted Lines (side by side) --%>
        <div class="grid grid-cols-1 xl:grid-cols-2 gap-6 mb-8">
          <%!-- Hot Spots --%>
          <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
            <div class="px-5 py-4 border-b border-gray-800 flex items-start justify-between">
              <div>
                <h2 class="font-semibold text-lg">🔥 Problematic Intersections</h2>
                <p class="text-gray-500 text-sm mt-1">Top 10 by delay count (24h)</p>
              </div>
              <.link
                navigate={~p"/map"}
                class="px-3 py-1.5 bg-amber-500/20 text-amber-400 rounded-lg text-sm hover:bg-amber-500/30 transition-colors"
              >
                🗺️ Map
              </.link>
            </div>
            <div class="overflow-x-auto max-h-80 overflow-y-auto">
              <%= if @hot_spots == [] do %>
                <div class="p-8 text-center text-gray-500">No data yet</div>
              <% else %>
                <table class="w-full text-sm">
                  <thead class="bg-gray-800/50 sticky top-0">
                    <tr class="text-left text-gray-400">
                      <th class="px-4 py-2 font-medium">#</th>
                      <th class="px-4 py-2 font-medium">Location</th>
                      <th class="px-4 py-2 font-medium">Delays</th>
                      <th class="px-4 py-2 font-medium">Time</th>
                      <th class="px-4 py-2 font-medium">Lines</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-800">
                    <%= for {spot, idx} <- Enum.with_index(@hot_spots, 1) do %>
                      <tr class="hover:bg-gray-800/50">
                        <td class="px-4 py-2">
                          <span class={[
                            "inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-bold",
                            rank_color(idx)
                          ]}>
                            {idx}
                          </span>
                        </td>
                        <td class="px-4 py-2">
                          <div class="text-sm">
                            <span class="text-gray-400">Near</span>
                            <span class="text-white ml-1">{spot.nearest_stop || "Unknown"}</span>
                          </div>
                          <a
                            href={"https://www.google.com/maps?q=#{spot.lat},#{spot.lon}"}
                            target="_blank"
                            class="text-xs text-gray-500 hover:text-amber-400 transition-colors"
                          >
                            📍 {Float.round(spot.lat, 4)}, {Float.round(spot.lon, 4)}
                          </a>
                        </td>
                        <td class="px-4 py-2 text-red-400 font-semibold">{spot.delay_count}</td>
                        <td class="px-4 py-2 text-amber-400">
                          {format_duration(spot.total_delay_seconds)}
                        </td>
                        <td class="px-4 py-2">
                          <div class="flex flex-wrap gap-1">
                            <%= for line <- Enum.take(spot.affected_lines, 4) do %>
                              <span class="px-1 py-0.5 bg-gray-800 rounded text-xs text-amber-300">
                                {line}
                              </span>
                            <% end %>
                            <%= if length(spot.affected_lines) > 4 do %>
                              <span class="text-gray-500 text-xs">
                                +{length(spot.affected_lines) - 4}
                              </span>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>
          </div>

          <%!-- Most Impacted Lines --%>
          <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
            <div class="px-5 py-4 border-b border-gray-800 flex items-start justify-between">
              <div>
                <h2 class="font-semibold text-lg">🚋 Most Impacted Lines</h2>
                <p class="text-gray-500 text-sm mt-1">Ranked by total delay time (24h)</p>
              </div>
              <.link
                navigate={~p"/line"}
                class="px-3 py-1.5 bg-amber-500/20 text-amber-400 rounded-lg text-sm hover:bg-amber-500/30 transition-colors"
              >
                ⏰ Hours
              </.link>
            </div>
            <div class="overflow-x-auto max-h-80 overflow-y-auto">
              <%= if @impacted_lines == [] do %>
                <div class="p-8 text-center text-gray-500">No data yet</div>
              <% else %>
                <table class="w-full text-sm">
                  <thead class="bg-gray-800/50 sticky top-0">
                    <tr class="text-left text-gray-400">
                      <th class="px-4 py-2 font-medium">#</th>
                      <th class="px-4 py-2 font-medium">Line</th>
                      <th class="px-4 py-2 font-medium">Delays</th>
                      <th class="px-4 py-2 font-medium">Blockages</th>
                      <th class="px-4 py-2 font-medium">Total</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-800">
                    <%= for {line_data, idx} <- Enum.with_index(@impacted_lines, 1) do %>
                      <tr class="hover:bg-gray-800/50">
                        <td class="px-4 py-2">
                          <span class={[
                            "inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-bold",
                            rank_color(idx)
                          ]}>
                            {idx}
                          </span>
                        </td>
                        <td class="px-4 py-2">
                          <.link
                            navigate={~p"/line/#{line_data.line}"}
                            class="px-2 py-0.5 bg-amber-500/20 text-amber-300 rounded font-mono font-bold hover:bg-amber-500/30 transition-colors"
                          >
                            {line_data.line} →
                          </.link>
                        </td>
                        <td class="px-4 py-2 text-orange-400 font-semibold">
                          {line_data.delay_count}
                        </td>
                        <td class="px-4 py-2 text-red-400">{line_data.blockage_count}</td>
                        <td class="px-4 py-2 text-amber-400">
                          {format_duration(line_data.total_seconds)}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- LIVE FEED: Active + Resolved --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Active Delays --%>
          <div class="bg-gray-900/70 rounded-xl border border-gray-800 overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-800 flex items-center justify-between">
              <h2 class="font-medium">
                🔴 Active Delays <span class="text-red-400 ml-1">({@active_count})</span>
              </h2>
              <span class="text-xs text-gray-500 animate-pulse">● LIVE</span>
            </div>
            <div class="divide-y divide-gray-800 max-h-64 overflow-y-auto">
              <%= if @active_delays == [] do %>
                <div class="p-6 text-center text-gray-500 text-sm">
                  ✨ No active delays
                </div>
              <% else %>
                <%= for delay <- Enum.take(@active_delays, 10) do %>
                  <div class="px-4 py-2 hover:bg-gray-800/50 text-sm">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <span class={[
                          "px-1.5 py-0.5 rounded text-xs font-medium",
                          classification_color(delay.classification)
                        ]}>
                          {delay.classification}
                        </span>
                        <span class="font-mono text-amber-300">L{delay.line}</span>
                        <%= if delay.near_intersection do %>
                          <span class="text-orange-400 text-xs">⚠️</span>
                        <% end %>
                      </div>
                      <span class="text-gray-500 text-xs">{duration_since(delay.started_at)}</span>
                    </div>
                  </div>
                <% end %>
                <%= if length(@active_delays) > 10 do %>
                  <div class="px-4 py-2 text-center text-gray-500 text-xs">
                    + {length(@active_delays) - 10} more
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>

          <%!-- Recent Resolved --%>
          <div class="bg-gray-900/70 rounded-xl border border-gray-800 overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-800">
              <h2 class="font-medium">✅ Recently Resolved</h2>
            </div>
            <div class="divide-y divide-gray-800 max-h-64 overflow-y-auto">
              <%= if @recent_resolved == [] do %>
                <div class="p-6 text-center text-gray-500 text-sm">
                  No resolved delays yet
                </div>
              <% else %>
                <%= for delay <- Enum.take(@recent_resolved, 10) do %>
                  <div class="px-4 py-2 hover:bg-gray-800/50 text-sm">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-2">
                        <span class={[
                          "px-1.5 py-0.5 rounded text-xs font-medium opacity-60",
                          classification_color(delay.classification)
                        ]}>
                          {delay.classification}
                        </span>
                        <span class="font-mono text-gray-400">L{delay.line}</span>
                      </div>
                      <div class="text-right">
                        <span class="text-green-400 text-xs font-medium">
                          {format_duration(delay.duration_seconds)}
                        </span>
                        <span class="text-gray-600 text-xs ml-2">{time_ago(delay.resolved_at)}</span>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Footer --%>
        <div class="mt-8 text-center text-gray-600 text-sm">
          Data source: GTFS-RT via mkuran.pl • Polling every 10s
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp duration_since(started_at) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
    end
  end

  defp time_ago(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      true -> "#{div(seconds, 3600)}h ago"
    end
  end

  defp classification_color("delay"), do: "bg-orange-500/20 text-orange-400"
  defp classification_color("blockage"), do: "bg-red-500/20 text-red-400"
  defp classification_color(_), do: "bg-gray-500/20 text-gray-400"

  defp rank_color(1), do: "bg-red-500 text-white"
  defp rank_color(2), do: "bg-orange-500 text-white"
  defp rank_color(3), do: "bg-amber-500 text-black"
  defp rank_color(_), do: "bg-gray-700 text-gray-300"

  defp format_duration(nil), do: "-"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end
end
