defmodule WawTramsWeb.DashboardLive do
  use WawTramsWeb, :live_view

  alias WawTrams.DelayEvent

  @refresh_interval 5_000  # 5 seconds

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

    socket
    |> assign(:active_delays, active_delays)
    |> assign(:active_count, length(active_delays))
    |> assign(:recent_resolved, recent_resolved)
    |> assign(:stats, stats)
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
    <Layouts.app flash={@flash}>
      <div class="min-h-screen bg-gray-950 text-gray-100">
        <div class="max-w-7xl mx-auto px-4 py-8">
          <%!-- Header --%>
          <div class="mb-8">
            <h1 class="text-3xl font-bold text-amber-400 tracking-tight">
              🚋 Warsaw Tram Delays
            </h1>
            <p class="text-gray-400 mt-1">
              Real-time delay monitoring • Updated <%= format_time(@last_updated) %>
            </p>
          </div>

          <%!-- Stats Cards --%>
          <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
            <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
              <div class="text-4xl font-bold text-red-400"><%= @active_count %></div>
              <div class="text-gray-400 text-sm mt-1">Active Delays</div>
            </div>

            <%= for stat <- @stats do %>
              <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
                <div class="text-4xl font-bold text-amber-400"><%= stat.count %></div>
                <div class="text-gray-400 text-sm mt-1">
                  <%= String.capitalize(stat.classification) %> (24h)
                </div>
                <div class="text-gray-500 text-xs mt-1">
                  avg <%= Float.round(stat.avg_duration_seconds || 0.0, 0) %>s
                </div>
              </div>
            <% end %>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <%!-- Active Delays --%>
            <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-800 flex items-center justify-between">
                <h2 class="font-semibold text-lg">
                  🔴 Active Delays
                  <span class="text-red-400 ml-2">(<%= @active_count %>)</span>
                </h2>
                <span class="text-xs text-gray-500 animate-pulse">● LIVE</span>
              </div>
              <div class="divide-y divide-gray-800 max-h-96 overflow-y-auto">
                <%= if @active_delays == [] do %>
                  <div class="p-8 text-center text-gray-500">
                    ✨ No active delays — trams running smoothly!
                  </div>
                <% else %>
                  <%= for delay <- @active_delays do %>
                    <div class="px-5 py-3 hover:bg-gray-800/50 transition-colors">
                      <div class="flex items-center justify-between">
                        <div>
                          <span class={[
                            "inline-block px-2 py-0.5 rounded text-xs font-medium mr-2",
                            classification_color(delay.classification)
                          ]}>
                            <%= delay.classification %>
                          </span>
                          <span class="font-mono text-amber-300">Line <%= delay.line %></span>
                        </div>
                        <span class="text-gray-400 text-sm">
                          <%= duration_since(delay.started_at) %>
                        </span>
                      </div>
                      <div class="text-gray-500 text-sm mt-1">
                        📍 (<%= Float.round(delay.lat, 4) %>, <%= Float.round(delay.lon, 4) %>)
                        <%= if delay.near_intersection do %>
                          <span class="text-orange-400 ml-2">⚠️ near intersection</span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

            <%!-- Recent Resolved --%>
            <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-800">
                <h2 class="font-semibold text-lg">
                  ✅ Recently Resolved
                </h2>
              </div>
              <div class="divide-y divide-gray-800 max-h-96 overflow-y-auto">
                <%= if @recent_resolved == [] do %>
                  <div class="p-8 text-center text-gray-500">
                    No resolved delays yet
                  </div>
                <% else %>
                  <%= for delay <- @recent_resolved do %>
                    <div class="px-5 py-3 hover:bg-gray-800/50 transition-colors">
                      <div class="flex items-center justify-between">
                        <div>
                          <span class={[
                            "inline-block px-2 py-0.5 rounded text-xs font-medium mr-2 opacity-60",
                            classification_color(delay.classification)
                          ]}>
                            <%= delay.classification %>
                          </span>
                          <span class="font-mono text-gray-300">Line <%= delay.line %></span>
                        </div>
                        <span class="text-green-400 text-sm font-medium">
                          <%= delay.duration_seconds %>s
                        </span>
                      </div>
                      <div class="text-gray-500 text-sm mt-1">
                        Resolved <%= time_ago(delay.resolved_at) %>
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
    </Layouts.app>
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

  defp classification_color("delay"), do: "bg-red-500/20 text-red-400"
  defp classification_color("blockage"), do: "bg-orange-500/20 text-orange-400"
  defp classification_color(_), do: "bg-gray-500/20 text-gray-400"
end
