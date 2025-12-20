defmodule WawTramsWeb.DashboardLive do
  use WawTramsWeb, :live_view

  alias WawTrams.Queries.ActiveDelays
  alias WawTrams.Cache
  alias WawTrams.WarsawTime
  import WawTramsWeb.Helpers.Formatters

  # 30 seconds base + jitter (still feels live, but 6x less DB load)
  @refresh_interval_base 30_000
  @refresh_jitter_max 5_000

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
    jitter = :rand.uniform(@refresh_jitter_max)
    Process.send_after(self(), :refresh, @refresh_interval_base + jitter)
  end

  defp assign_data(socket) do
    # Active delays are NOT cached - they're truly real-time
    active_delays = ActiveDelays.active()
    recent_resolved = ActiveDelays.recent_resolved(20)

    # Lines use cache to reduce DB load
    impacted_lines = Cache.get_dashboard_impacted_lines(limit: 10)

    socket
    |> assign(:active_delays, active_delays)
    |> assign(:active_count, length(active_delays))
    |> assign(:recent_resolved, recent_resolved)
    |> assign(:impacted_lines, impacted_lines)
    |> assign(:last_updated, DateTime.utc_now())
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
            <div class="text-gray-400 font-medium mb-2">{gettext("Legend")}</div>
            <div class="flex flex-wrap gap-x-6 gap-y-1">
              <div class="flex items-center gap-2">
                <span class="px-2 py-0.5 rounded text-xs font-medium bg-orange-500/20 text-orange-400">
                  {gettext("delay")}
                </span>
                <span class="text-gray-500">{gettext(">30s away from platform")}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="px-2 py-0.5 rounded text-xs font-medium bg-purple-500/20 text-purple-400">
                  {gettext("long")}
                </span>
                <span class="text-gray-500">{gettext(">2 min at intersection")}</span>
              </div>
              <div class="flex items-center gap-2">
                <span class="px-2 py-0.5 rounded text-xs font-medium bg-red-500/20 text-red-400">
                  {gettext("blockage")}
                </span>
                <span class="text-gray-500">{gettext(">3 min at platform")}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- LIVE FEED + Lines (2/3 + 1/3 layout) --%>
        <div class="grid grid-cols-1 xl:grid-cols-3 gap-6">
          <%!-- Live Feed Column (2/3 width) --%>
          <div class="xl:col-span-2 grid grid-cols-1 lg:grid-cols-2 gap-6">
            <%!-- Active Delays --%>
            <div class="bg-gray-900/70 rounded-xl border border-gray-800 overflow-hidden flex flex-col min-h-[360px]">
              <div class="px-5 py-3 border-b border-gray-800 flex items-center justify-between shrink-0">
                <h2 class="font-medium">
                  🔴 {gettext("Active Delays")}
                  <span class="text-red-400 ml-1">({@active_count})</span>
                </h2>
                <span class="text-xs text-gray-500 animate-pulse">● {gettext("LIVE")}</span>
              </div>
              <div class="divide-y divide-gray-800 flex-1 overflow-y-auto">
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
            <div class="bg-gray-900/70 rounded-xl border border-gray-800 overflow-hidden flex flex-col min-h-[360px]">
              <div class="px-5 py-3 border-b border-gray-800 shrink-0">
                <h2 class="font-medium">✅ {gettext("Recently Resolved")}</h2>
              </div>
              <div class="divide-y divide-gray-800 flex-1 overflow-y-auto">
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
                              title={gettext("Long delay: stopped >2 minutes")}
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
                          <span class="text-gray-600 text-xs ml-2">
                            {time_ago(delay.resolved_at)}
                          </span>
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Most Impacted Lines (1/3 width sidebar) --%>
          <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden h-fit">
            <div class="px-5 py-4 border-b border-gray-800 flex items-start justify-between">
              <div>
                <h2 class="font-semibold text-lg">🚋 {gettext("Lines")}</h2>
                <p class="text-gray-500 text-sm mt-1">{gettext("By delay time (24h)")}</p>
              </div>
              <.link
                navigate={~p"/line"}
                class="px-3 py-1.5 bg-amber-500/20 text-amber-400 rounded-lg text-sm hover:bg-amber-500/30 transition-colors"
              >
                {gettext("Details")} →
              </.link>
            </div>
            <div class="divide-y divide-gray-800 max-h-[500px] overflow-y-auto">
              <%= if @impacted_lines == [] do %>
                <div class="p-8 text-center text-gray-500">{gettext("No data")}</div>
              <% else %>
                <%= for {line_data, idx} <- Enum.with_index(@impacted_lines, 1) do %>
                  <.link
                    navigate={~p"/line/#{line_data.line}"}
                    class="flex items-center justify-between px-4 py-3 hover:bg-gray-800/50 transition-colors"
                  >
                    <div class="flex items-center gap-3">
                      <span class={[
                        "inline-flex items-center justify-center w-6 h-6 rounded-full text-xs font-bold",
                        rank_color(idx)
                      ]}>
                        {idx}
                      </span>
                      <span class="font-mono font-bold text-amber-300 text-lg">{line_data.line}</span>
                    </div>
                    <div class="text-right">
                      <div class="text-amber-400 font-medium">
                        {format_duration(line_data.total_seconds)}
                      </div>
                      <div class="text-gray-500 text-xs">
                        {line_data.delay_count} {gettext("delays")}
                      </div>
                    </div>
                  </.link>
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

  # Helper functions (UI-specific, not shared)

  defp format_time(datetime) do
    WarsawTime.format_time(datetime)
  end

  defp classification_color("delay"), do: "bg-orange-500/20 text-orange-400"
  defp classification_color("blockage"), do: "bg-red-500/20 text-red-400"
  defp classification_color(_), do: "bg-gray-500/20 text-gray-400"

  defp rank_color(1), do: "bg-red-500 text-white"
  defp rank_color(2), do: "bg-orange-500 text-white"
  defp rank_color(3), do: "bg-amber-500 text-black"
  defp rank_color(_), do: "bg-gray-700 text-gray-300"
end
