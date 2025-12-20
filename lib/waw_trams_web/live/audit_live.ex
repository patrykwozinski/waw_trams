defmodule WawTramsWeb.AuditLive do
  @moduledoc """
  Audit Dashboard - Infrastructure Report Card

  A political tool showing exactly where and how much money is wasted
  on failed tram priority systems.
  """
  use WawTramsWeb, :live_view

  alias WawTrams.Audit.{Summary, Intersection}
  alias WawTrams.Queries.ActiveDelays
  alias WawTramsWeb.Components.Audit.{MethodologyModal, Leaderboard, ReportCard}
  import WawTramsWeb.Helpers.Formatters

  # Base refresh interval with jitter to prevent thundering herd
  @refresh_interval_base :timer.minutes(5)
  @refresh_jitter_max :timer.seconds(30)

  @impl true
  def mount(_params, _session, socket) do
    # Default empty stats to prevent KeyError during initial render
    empty_stats = %{
      cost: %{total: 0},
      total_hours_formatted: "0m",
      total_delays: 0,
      multi_cycle_count: 0
    }

    socket =
      socket
      |> assign(:page_title, gettext("Infrastructure Report Card"))
      |> assign(:date_range, "24h")
      |> assign(:line_filter, nil)
      |> assign(:selected, nil)
      |> assign(:loading, true)
      |> assign(:mobile_tab, "map")
      |> assign(:stats, empty_stats)
      |> assign(:leaderboard, [])
      |> assign(:leaderboard_coverage_pct, 0)
      |> assign(:selected_heatmap, %{grid: [], max_count: 0, total_delays: 0})
      |> assign(:show_methodology, false)
      |> assign(:leaderboard_refresh_timer, nil)
      # Track active (unresolved) delays for live ticker
      |> assign(:active_delays, %{})

    socket =
      if connected?(socket) do
        # Subscribe to real-time delay updates
        Phoenix.PubSub.subscribe(WawTrams.PubSub, "delays")
        # Add random jitter to prevent all users refreshing at exactly the same time
        schedule_refresh()
        send(self(), :load_initial_data)

        # Load currently active delays from DB to show live bubbles
        active_delays = load_active_delays()
        assign(socket, :active_delays, active_delays)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_data(socket)}
  end

  # Debounce delay for leaderboard refresh (3 seconds)
  @leaderboard_debounce_ms 3_000

  # Real-time delay events
  # delay_created: Track active delay for live ticker
  # delay_resolved: Explosion effect, update final stats, refresh leaderboard
  @impl true
  def handle_info({:delay_created, event}, socket) do
    if event.near_intersection do
      # Track this delay as "active" with start time
      active_delay = %{
        lat: event.lat,
        lon: event.lon,
        line: event.line,
        started_at: DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      }

      active_delays = Map.put(socket.assigns.active_delays, event.vehicle_id, active_delay)

      # Push to JS for live bubble on map
      socket =
        socket
        |> assign(:active_delays, active_delays)
        |> push_event("delay_started", active_delay)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:delay_resolved, event}, socket) do
    # Delay resolved - NOW we know the final duration and cost
    if event.near_intersection do
      # Calculate final cost
      duration = event.duration_seconds || 0
      hour = DateTime.utc_now().hour
      cost = WawTrams.Audit.CostCalculator.calculate(duration, hour)

      # Remove from active delays
      active_delays = Map.delete(socket.assigns.active_delays, event.vehicle_id)

      # EXPLOSION animation with final cost
      socket =
        socket
        |> assign(:active_delays, active_delays)
        |> push_event("delay_resolved", %{
          vehicle_id: event.vehicle_id,
          lat: event.lat,
          lon: event.lon,
          line: event.line,
          duration: duration,
          cost: cost.total
        })

      # Update stats with final duration and cost
      stats = socket.assigns.stats

      updated_stats = %{
        stats
        | total_delays: stats.total_delays + 1,
          total_seconds: Map.get(stats, :total_seconds, 0) + duration,
          cost: %{stats.cost | total: stats.cost.total + cost.total}
      }

      # Schedule debounced leaderboard refresh (final data now available)
      socket =
        socket
        |> assign(:stats, updated_stats)
        |> schedule_leaderboard_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_leaderboard, socket) do
    # Refresh leaderboard from database
    since = get_since(socket.assigns.date_range)
    line = socket.assigns.line_filter
    opts = [since: since] ++ if(line, do: [line: line], else: [])

    leaderboard = Summary.leaderboard(opts ++ [limit: 20])

    # Push updated data to map
    socket = push_event(socket, "leaderboard_data", %{data: leaderboard})

    {:noreply,
     socket
     |> assign(:leaderboard, leaderboard)
     |> assign(:leaderboard_refresh_timer, nil)}
  end

  # Debounce leaderboard refresh - cancels previous timer if exists
  defp schedule_leaderboard_refresh(socket) do
    # Cancel existing timer if any
    if timer = socket.assigns[:leaderboard_refresh_timer] do
      Process.cancel_timer(timer)
    end

    # Schedule new refresh
    timer = Process.send_after(self(), :refresh_leaderboard, @leaderboard_debounce_ms)
    assign(socket, :leaderboard_refresh_timer, timer)
  end

  # Schedules next refresh with random jitter to spread DB load
  defp schedule_refresh do
    jitter = :rand.uniform(@refresh_jitter_max)
    Process.send_after(self(), :refresh, @refresh_interval_base + jitter)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    locale = params["locale"]

    if locale in ["en", "pl"] do
      Gettext.put_locale(WawTramsWeb.Gettext, locale)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("request_leaderboard", _params, socket) do
    {:noreply, push_event(socket, "leaderboard_data", %{data: socket.assigns.leaderboard})}
  end

  @impl true
  def handle_event("select_intersection", %{"lat" => lat, "lon" => lon}, socket) do
    lat = String.to_float(lat)
    lon = String.to_float(lon)

    # Find the intersection in leaderboard (already has all the stats)
    selected =
      Enum.find(socket.assigns.leaderboard, fn spot ->
        Float.round(spot.lat, 4) == Float.round(lat, 4) and
          Float.round(spot.lon, 4) == Float.round(lon, 4)
      end)

    if selected do
      # Only fetch additional details not in leaderboard
      since = get_since(socket.assigns.date_range)
      heatmap = Intersection.heatmap(lat, lon, since: since)
      {affected_lines, _} = Intersection.get_metadata(lat, lon, since: since)

      # Use leaderboard data directly, just add extras
      selected_with_extras =
        selected
        |> Map.put(:affected_lines, affected_lines)

      socket =
        socket
        |> assign(:selected, selected_with_extras)
        |> assign(:selected_heatmap, heatmap)
        |> assign(:mobile_tab, "detail")
        |> push_event("fly_to", %{lat: lat, lon: lon})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("deselect", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
     |> assign(:mobile_tab, "list")
     |> push_event("reset_view", %{})}
  end

  @impl true
  def handle_event("set_mobile_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :mobile_tab, tab)}
  end

  @impl true
  def handle_event("change_date_range", %{"range" => range}, socket) do
    socket =
      socket
      |> assign(:date_range, range)
      |> assign(:selected, nil)
      |> load_data()

    {:noreply, push_event(socket, "leaderboard_data", %{data: socket.assigns.leaderboard})}
  end

  @impl true
  def handle_event("change_line", %{"line" => ""}, socket) do
    socket =
      socket
      |> assign(:line_filter, nil)
      |> assign(:selected, nil)
      |> load_data()

    {:noreply, push_event(socket, "leaderboard_data", %{data: socket.assigns.leaderboard})}
  end

  @impl true
  def handle_event("change_line", %{"line" => line}, socket) do
    socket =
      socket
      |> assign(:line_filter, line)
      |> assign(:selected, nil)
      |> load_data()

    {:noreply, push_event(socket, "leaderboard_data", %{data: socket.assigns.leaderboard})}
  end

  @impl true
  def handle_event("toggle_methodology", _params, socket) do
    {:noreply, assign(socket, :show_methodology, !socket.assigns.show_methodology)}
  end

  defp load_data(socket) do
    since = get_since(socket.assigns.date_range)
    line = socket.assigns.line_filter
    opts = [since: since] ++ if(line, do: [line: line], else: [])

    stats = Summary.stats(opts)
    leaderboard = Summary.leaderboard(opts ++ [limit: 20])

    # Calculate what % of total cost the top 20 represents
    leaderboard_cost = Enum.reduce(leaderboard, 0, fn spot, acc -> acc + spot.cost.total end)

    coverage_pct =
      if stats.cost.total > 0 do
        Float.round(leaderboard_cost / stats.cost.total * 100, 0)
      else
        0
      end

    socket
    |> assign(:stats, stats)
    |> assign(:leaderboard, leaderboard)
    |> assign(:leaderboard_coverage_pct, coverage_pct)
  end

  defp get_since("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  defp get_since("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp get_since("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp get_since(_), do: DateTime.add(DateTime.utc_now(), -1, :day)

  # Load currently active delays from DB for live bubbles
  defp load_active_delays do
    ActiveDelays.active()
    |> Enum.filter(& &1.near_intersection)
    |> Enum.reduce(%{}, fn delay, acc ->
      Map.put(acc, delay.vehicle_id, %{
        lat: delay.lat,
        lon: delay.lon,
        line: delay.line,
        started_at: DateTime.to_unix(delay.started_at, :millisecond)
      })
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />

    <div class="h-screen flex flex-col bg-gray-950 text-gray-100">
      <%!-- Loading overlay --%>
      <%= if @loading do %>
        <div class="absolute inset-0 z-50 bg-gray-950/80 flex items-center justify-center">
          <div class="flex flex-col items-center gap-4">
            <div class="w-12 h-12 border-4 border-red-500 border-t-transparent rounded-full animate-spin">
            </div>
            <p class="text-gray-400">{gettext("Loading data...")}</p>
          </div>
        </div>
      <% end %>

      <%!-- Site Header --%>
      <Layouts.site_header active={:audit} />

      <%!-- Hero Section - The Headline --%>
      <div class="px-4 md:px-6 py-3 md:py-4 bg-gradient-to-b from-gray-900 to-gray-950 border-b border-gray-800">
        <div class="max-w-[1600px] mx-auto">
          <%!-- Filters row --%>
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-2 md:gap-4">
              <form phx-change="change_date_range" class="inline">
                <select
                  name="range"
                  class="bg-gray-800 border border-gray-700 rounded px-2 md:px-3 py-1 md:py-1.5 text-xs md:text-sm text-gray-300"
                >
                  <option value="24h" selected={@date_range == "24h"}>{gettext("Last 24h")}</option>
                  <option value="7d" selected={@date_range == "7d"}>{gettext("Last 7 days")}</option>
                  <option value="30d" selected={@date_range == "30d"}>
                    {gettext("Last 30 days")}
                  </option>
                </select>
              </form>
              <form phx-change="change_line" class="inline">
                <select
                  name="line"
                  class="bg-gray-800 border border-gray-700 rounded px-2 md:px-3 py-1 md:py-1.5 text-xs md:text-sm text-gray-300"
                >
                  <option value="">{gettext("All lines")}</option>
                  <%= for line <- 1..79 do %>
                    <option value={to_string(line)} selected={@line_filter == to_string(line)}>
                      {line}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>
            <button
              phx-click="toggle_methodology"
              class="text-gray-400 hover:text-amber-400 transition-colors flex items-center gap-1 text-sm"
              title={gettext("How is cost calculated?")}
            >
              <.icon name="hero-question-mark-circle" class="w-5 h-5" />
              <span class="hidden md:inline">{gettext("How is this calculated?")}</span>
            </button>
          </div>

          <%!-- Big Headline - updates on delay resolve --%>
          <div
            class="text-center"
            id="global-ticker"
            phx-hook="GlobalTickerHook"
            data-base-cost={@stats.cost.total}
            data-base-delays={@stats.total_delays}
            data-base-seconds={Map.get(@stats, :total_seconds, 0)}
            data-currency={currency_symbol()}
          >
            <h1 class="text-3xl md:text-5xl font-bold mb-1">
              <span id="ticker-cost" class="text-red-400 tabular-nums">
                {format_cost(@stats.cost.total)}
              </span>
              <span class="text-white">{gettext("Wasted")}</span>
            </h1>
            <p class="text-sm md:text-base text-gray-400">
              {period_label(@date_range)}
              <span class="text-gray-600 mx-2">•</span>
              <span id="ticker-delays" class="tabular-nums">
                {format_number(@stats.total_delays)}
              </span>
              {gettext("delays")}
              <span class="text-gray-600 mx-2">•</span>
              <span id="ticker-time" class="text-amber-400 tabular-nums">
                {@stats.total_hours_formatted}
              </span>
              {gettext("lost")}
            </p>
          </div>
        </div>
      </div>

      <%!-- Mobile tab navigation --%>
      <div class="md:hidden flex border-b border-gray-800 bg-gray-900">
        <button
          phx-click="set_mobile_tab"
          phx-value-tab="map"
          class={"flex-1 py-3 text-sm font-medium #{if @mobile_tab == "map", do: "text-red-400 border-b-2 border-red-400", else: "text-gray-500"}"}
        >
          🗺️ {gettext("Map")}
        </button>
        <button
          phx-click="set_mobile_tab"
          phx-value-tab="list"
          class={"flex-1 py-3 text-sm font-medium #{if @mobile_tab == "list", do: "text-red-400 border-b-2 border-red-400", else: "text-gray-500"}"}
        >
          📋 {gettext("List")}
        </button>
        <%= if @selected do %>
          <button
            phx-click="set_mobile_tab"
            phx-value-tab="detail"
            class={"flex-1 py-3 text-sm font-medium #{if @mobile_tab == "detail", do: "text-red-400 border-b-2 border-red-400", else: "text-gray-500"}"}
          >
            📊 {gettext("Details")}
          </button>
        <% end %>
      </div>

      <%!-- Split screen: Map + Sidebar (desktop) / Tabbed (mobile) --%>
      <div class="flex-1 flex overflow-hidden">
        <%!-- Map (left 2/3 on desktop, full on mobile map tab) --%>
        <div class={"flex-1 relative #{if @mobile_tab != "map", do: "hidden md:block"}"}>
          <div
            id="audit-map"
            phx-hook="AuditMapHook"
            phx-update="ignore"
            data-currency={currency_symbol()}
            data-active-delays={Jason.encode!(Map.values(@active_delays))}
            class="absolute inset-0"
          >
          </div>
        </div>

        <%!-- Sidebar (right 1/3 on desktop, full on mobile list/detail tab) --%>
        <div class={"w-full md:w-[28rem] bg-gray-900 md:border-l border-gray-800 overflow-y-auto #{if @mobile_tab == "map", do: "hidden md:block"}"}>
          <%= if @selected != nil and (@mobile_tab == "detail" or @mobile_tab != "list") do %>
            <ReportCard.report_card selected={@selected} heatmap={@selected_heatmap} />
          <% else %>
            <Leaderboard.leaderboard data={@leaderboard} coverage_pct={@leaderboard_coverage_pct} />
          <% end %>
        </div>
      </div>

      <%!-- Methodology Modal --%>
      <%= if @show_methodology do %>
        <MethodologyModal.methodology_modal />
      <% end %>
    </div>
    """
  end

  # Helper for period labels
  defp period_label("24h"), do: gettext("Today")
  defp period_label("7d"), do: gettext("This Week")
  defp period_label("30d"), do: gettext("This Month")
  defp period_label(_), do: ""
end
