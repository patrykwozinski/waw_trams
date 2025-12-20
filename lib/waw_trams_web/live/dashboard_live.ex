defmodule WawTramsWeb.DashboardLive do
  use WawTramsWeb, :live_view

  alias WawTrams.Queries.{ActiveDelays, HotSpots}
  alias WawTrams.Analytics.Stats
  alias WawTrams.WarsawTime

  # 5 seconds
  @refresh_interval 5_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      # Subscribe to delay updates
      Phoenix.PubSub.subscribe(WawTrams.PubSub, "delays")
      # Schedule periodic refresh
      schedule_refresh()
    end

    locale = session["locale"] || "en"
    Gettext.put_locale(WawTramsWeb.Gettext, locale)

    {:ok, socket |> assign(:locale, locale) |> assign_data()}
  end

  @impl true
  def handle_params(%{"locale" => locale}, _uri, socket) when locale in ["en", "pl"] do
    Gettext.put_locale(WawTramsWeb.Gettext, locale)
    {:noreply, assign(socket, :locale, locale)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
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
    active_delays = ActiveDelays.active()
    recent_resolved = ActiveDelays.recent_resolved(20)
    stats = Stats.for_period()
    hot_spots = HotSpots.hot_spots(limit: 10)
    hot_spot_summary = HotSpots.hot_spot_summary()
    impacted_lines = HotSpots.impacted_lines(limit: 10)
    multi_cycle_count = Stats.multi_cycle_count()

    # Summarize stats for cleaner display
    stats_summary = summarize_stats(stats, multi_cycle_count)

    socket
    |> assign(:active_delays, active_delays)
    |> assign(:active_count, length(active_delays))
    |> assign(:recent_resolved, recent_resolved)
    |> assign(:stats_summary, stats_summary)
    |> assign(:hot_spots, hot_spots)
    |> assign(:hot_spot_summary, hot_spot_summary)
    |> assign(:impacted_lines, impacted_lines)
    |> assign(:last_updated, DateTime.utc_now())
  end

  defp summarize_stats(stats, multi_cycle_count) do
    delays = Enum.find(stats, %{count: 0}, &(&1.classification == "delay")).count
    blockages = Enum.find(stats, %{count: 0}, &(&1.classification == "blockage")).count

    %{
      delays: delays,
      blockages: blockages,
      total: delays + blockages,
      multi_cycle: multi_cycle_count
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100 flex flex-col">
      <%!-- Site Header --%>
      <Layouts.site_header active={:dashboard} />

      <div class="flex-1 max-w-[1600px] w-full mx-auto px-6 py-8">
        <%!-- Page Header --%>
        <div class="mb-8 flex flex-wrap items-start justify-between gap-6">
          <div>
            <h1 class="text-3xl font-bold text-amber-400 tracking-tight">
              📊 {gettext("Real-time Dashboard")}
            </h1>
            <p class="text-gray-400 mt-1">
              {gettext("Live delay monitoring")} • {gettext("Updated")} {format_time(@last_updated)}
            </p>
          </div>

          <%!-- Legend --%>
          <div class="bg-gray-900/50 rounded-lg px-4 py-3 border border-gray-800 text-sm">
            <div class="text-gray-400 font-medium mb-2">{gettext("Classification Legend")}</div>
            <div class="flex flex-wrap gap-x-6 gap-y-1">
              <div class="flex items-center gap-2">
                <span class="px-2 py-0.5 rounded text-xs font-medium bg-orange-500/20 text-orange-400">
                  {gettext("delay")}
                </span>
                <span class="text-gray-500">{gettext("30s – 3min stop")}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/20 text-red-400">
                  {gettext("blockage")}
                </span>
                <span class="text-gray-500">{gettext("> 3min stop")}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-purple-400">⚡</span>
                <span class="text-gray-500">{gettext("priority failure (>120s)")}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-orange-400">⚠️</span>
                <span class="text-gray-500">{gettext("near traffic signal")}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Stats Cards --%>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-red-400">{@active_count}</div>
            <div class="text-gray-400 text-sm mt-1">🔴 {gettext("Active Now")}</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-orange-400">{@stats_summary.delays}</div>
            <div class="text-gray-400 text-sm mt-1">{gettext("Delays (24h)")}</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-red-400">{@stats_summary.blockages}</div>
            <div class="text-gray-400 text-sm mt-1">{gettext("Blockages (24h)")}</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-purple-400">{@stats_summary.multi_cycle}</div>
            <div class="text-gray-400 text-sm mt-1">⚡ {gettext("Priority Failures (24h)")}</div>
          </div>
          <div class="bg-gray-900 rounded-xl p-5 border border-gray-800">
            <div class="text-4xl font-bold text-amber-400">
              {format_time_lost(@hot_spot_summary.total_delay_minutes)}
            </div>
            <div class="text-gray-400 text-sm mt-1">⏱️ {gettext("Time Lost (24h)")}</div>
          </div>
        </div>

        <%!-- KEY INSIGHTS: Hot Spots + Most Impacted Lines (side by side) --%>
        <div class="grid grid-cols-1 xl:grid-cols-2 gap-6 mb-8">
          <%!-- Hot Spots --%>
          <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
            <div class="px-5 py-4 border-b border-gray-800 flex items-start justify-between">
              <div>
                <h2 class="font-semibold text-lg">🔥 {gettext("Intersection Hot Spots")}</h2>
                <p class="text-gray-500 text-sm mt-1">{gettext("Top 10 by delay count (24h)")}</p>
              </div>
              <.link
                navigate={~p"/"}
                class="px-3 py-1.5 bg-amber-500/20 text-amber-400 rounded-lg text-sm hover:bg-amber-500/30 transition-colors"
              >
                🚨 {gettext("Audit")}
              </.link>
            </div>
            <div class="overflow-x-auto max-h-80 overflow-y-auto">
              <%= if @hot_spots == [] do %>
                <div class="p-8 text-center text-gray-500">{gettext("No data")}</div>
              <% else %>
                <table class="w-full text-sm">
                  <thead class="bg-gray-800/50 sticky top-0">
                    <tr class="text-left text-gray-400">
                      <th class="px-4 py-2 font-medium">#</th>
                      <th class="px-4 py-2 font-medium">{gettext("Location")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Delays")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Time")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Lines")}</th>
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
                            <%= if !spot.is_intersection do %>
                              <span class="text-gray-400">{gettext("Near")}</span>
                            <% end %>
                            <span class={["text-white", !spot.is_intersection && "ml-1"]}>
                              {spot.location_name || gettext("Unknown")}
                            </span>
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
                <h2 class="font-semibold text-lg">🚋 {gettext("Most Impacted Lines")}</h2>
                <p class="text-gray-500 text-sm mt-1">
                  {gettext("Ranked by total delay time (24h)")}
                </p>
              </div>
              <.link
                navigate={~p"/line"}
                class="px-3 py-1.5 bg-amber-500/20 text-amber-400 rounded-lg text-sm hover:bg-amber-500/30 transition-colors"
              >
                ⏰ {gettext("Hours")}
              </.link>
            </div>
            <div class="overflow-x-auto max-h-80 overflow-y-auto">
              <%= if @impacted_lines == [] do %>
                <div class="p-8 text-center text-gray-500">{gettext("No data")}</div>
              <% else %>
                <table class="w-full text-sm">
                  <thead class="bg-gray-800/50 sticky top-0">
                    <tr class="text-left text-gray-400">
                      <th class="px-4 py-2 font-medium">#</th>
                      <th class="px-4 py-2 font-medium">{gettext("Line")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Delays")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Blockages")}</th>
                      <th class="px-4 py-2 font-medium">{gettext("Total")}</th>
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
                🔴 {gettext("Active Delays")} <span class="text-red-400 ml-1">({@active_count})</span>
              </h2>
              <span class="text-xs text-gray-500 animate-pulse">● {gettext("LIVE")}</span>
            </div>
            <div class="divide-y divide-gray-800 max-h-64 overflow-y-auto">
              <%= if @active_delays == [] do %>
                <div class="p-6 text-center text-gray-500 text-sm">
                  ✨ {gettext("No active delays")}
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
                      <span
                        id={"timer-#{delay.id}"}
                        class="text-gray-500 text-xs font-mono"
                        phx-hook=".LiveTimer"
                        data-started={DateTime.to_iso8601(delay.started_at)}
                      >
                        {duration_since(delay.started_at)}
                      </span>
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
              <h2 class="font-medium">✅ {gettext("Recently Resolved")}</h2>
            </div>
            <div class="divide-y divide-gray-800 max-h-64 overflow-y-auto">
              <%= if @recent_resolved == [] do %>
                <div class="p-6 text-center text-gray-500 text-sm">
                  {gettext("No recent resolved delays")}
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
                        <%= if delay.multi_cycle do %>
                          <span
                            class="text-purple-400 text-xs"
                            title={
                              gettext(
                                "Priority failure: tram waited through multiple signal cycles (>120s)"
                              )
                            }
                          >
                            ⚡
                          </span>
                        <% end %>
                      </div>
                      <div class="text-right">
                        <span class={[
                          "text-xs font-medium",
                          if(delay.multi_cycle, do: "text-purple-400", else: "text-green-400")
                        ]}>
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
      </div>

      <%!-- Site Footer --%>
      <Layouts.site_footer />
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".LiveTimer">
      export default {
        mounted() {
          this.startedAt = new Date(this.el.dataset.started);
          this.updateTimer();
          this.interval = setInterval(() => this.updateTimer(), 1000);
        },
        updated() {
          this.startedAt = new Date(this.el.dataset.started);
          this.updateTimer();
        },
        destroyed() {
          clearInterval(this.interval);
        },
        updateTimer() {
          const now = new Date();
          const seconds = Math.floor((now - this.startedAt) / 1000);

          let text;
          if (seconds < 60) {
            text = `${seconds}s`;
          } else if (seconds < 3600) {
            const m = Math.floor(seconds / 60);
            const s = seconds % 60;
            text = `${m}m ${s}s`;
          } else {
            const h = Math.floor(seconds / 3600);
            const m = Math.floor((seconds % 3600) / 60);
            text = `${h}h ${m}m`;
          }
          this.el.innerText = text;
        }
      }
    </script>
    """
  end

  # Helper functions

  defp format_time(datetime) do
    WarsawTime.format_time(datetime)
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

  defp format_time_lost(minutes) when minutes < 60, do: "#{minutes}m"

  defp format_time_lost(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}h #{mins}m"
  end
end
