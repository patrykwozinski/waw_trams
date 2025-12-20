defmodule WawTramsWeb.AuditLive do
  @moduledoc """
  Audit Dashboard - Infrastructure Report Card

  A political tool showing exactly where and how much money is wasted
  on failed tram priority systems.
  """
  use WawTramsWeb, :live_view

  alias WawTrams.Audit.{Summary, Intersection}

  @refresh_interval :timer.seconds(30)

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
      |> assign(:date_range, "7d")
      |> assign(:line_filter, nil)
      |> assign(:selected, nil)
      |> assign(:loading, true)
      |> assign(:mobile_tab, "map")
      |> assign(:stats, empty_stats)
      |> assign(:leaderboard, [])
      |> assign(:leaderboard_coverage_pct, 0)
      |> assign(:selected_heatmap, %{grid: [], max_count: 0, total_delays: 0})
      |> assign(:show_methodology, false)

    if connected?(socket) do
      :timer.send_interval(@refresh_interval, :refresh)
      send(self(), :load_initial_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Handle locale changes
    if params["locale"] do
      Gettext.put_locale(WawTramsWeb.Gettext, params["locale"])
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
     |> push_event("reset_view", %{reset: true})}
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
  defp get_since(_), do: DateTime.add(DateTime.utc_now(), -7, :day)

  @impl true
  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <style>
      .severity-red { background: rgba(239, 68, 68, 0.2); border-color: #ef4444; }
      .severity-orange { background: rgba(249, 115, 22, 0.2); border-color: #f97316; }
      .severity-yellow { background: rgba(234, 179, 8, 0.2); border-color: #eab308; }
    </style>

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

      <%!-- Content Header with filters and stats --%>
      <div class="px-4 md:px-6 py-3 md:py-4 bg-gray-900/50 border-b border-gray-800">
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-3 mb-3 md:mb-4 max-w-[1600px] mx-auto">
          <div>
            <h1 class="text-xl md:text-2xl font-bold text-red-400">
              🚨 {gettext("Infrastructure Report Card")}
            </h1>
            <p class="text-gray-500 text-xs md:text-sm hidden md:block">
              {gettext("Where is money being wasted on tram delays?")}
            </p>
          </div>
          <div class="flex items-center gap-2 md:gap-4 flex-wrap">
            <%!-- Date range filter --%>
            <form phx-change="change_date_range" class="inline">
              <select
                name="range"
                class="bg-gray-800 border border-gray-700 rounded px-2 md:px-3 py-1 md:py-1.5 text-xs md:text-sm text-gray-300"
              >
                <option value="24h" selected={@date_range == "24h"}>{gettext("Last 24h")}</option>
                <option value="7d" selected={@date_range == "7d"}>{gettext("Last 7 days")}</option>
                <option value="30d" selected={@date_range == "30d"}>{gettext("Last 30 days")}</option>
              </select>
            </form>

            <%!-- Line filter --%>
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
        </div>

        <%!-- Big numbers - responsive grid --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-2 md:gap-4 max-w-[1600px] mx-auto">
          <div class="bg-gray-800/50 rounded-lg p-2 md:p-4 border border-gray-700">
            <div class="text-xl md:text-3xl font-bold text-red-400">
              {format_cost(@stats.cost.total)}
            </div>
            <div class="text-gray-500 text-xs md:text-sm flex items-center gap-2">
              {gettext("Cost at Intersections")}
              <button
                phx-click="toggle_methodology"
                class="text-amber-400 hover:text-amber-300 bg-gray-700 hover:bg-gray-600 rounded-full p-1 transition-colors"
                title={gettext("How is cost calculated?")}
              >
                <.icon name="hero-question-mark-circle" class="w-5 h-5" />
              </button>
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-2 md:p-4 border border-gray-700">
            <div class="text-xl md:text-3xl font-bold text-amber-400">
              {@stats.total_hours_formatted}
            </div>
            <div class="text-gray-500 text-xs md:text-sm">
              {gettext("Time Lost at Intersections")}
            </div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-2 md:p-4 border border-gray-700">
            <div class="text-xl md:text-3xl font-bold text-orange-400">
              {format_number(@stats.total_delays)}
            </div>
            <div class="text-gray-500 text-xs md:text-sm">{gettext("Intersection Delays")}</div>
          </div>
          <div class="bg-gray-800/50 rounded-lg p-2 md:p-4 border border-gray-700">
            <div class="text-xl md:text-3xl font-bold text-purple-400">
              {format_number(@stats.multi_cycle_count)}
            </div>
            <div class="text-gray-500 text-xs md:text-sm">{gettext("Priority Failures")}</div>
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
            class="absolute inset-0"
          >
          </div>
        </div>

        <%!-- Sidebar (right 1/3 on desktop, full on mobile list/detail tab) --%>
        <div class={"w-full md:w-[28rem] bg-gray-900 md:border-l border-gray-800 overflow-y-auto #{if @mobile_tab == "map", do: "hidden md:block"}"}>
          <%= if @selected != nil and (@mobile_tab == "detail" or @mobile_tab != "list") do %>
            <.report_card selected={@selected} heatmap={@selected_heatmap} />
          <% else %>
            <.leaderboard data={@leaderboard} coverage_pct={@leaderboard_coverage_pct} />
          <% end %>
        </div>
      </div>

      <%!-- Methodology Modal --%>
      <%= if @show_methodology do %>
        <.methodology_modal />
      <% end %>
    </div>
    """
  end

  # Cost Methodology Modal
  defp methodology_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-[1000] flex items-center justify-center bg-black/70"
      phx-click="toggle_methodology"
    >
      <div
        class="bg-gray-900 border border-gray-700 rounded-xl max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto"
        phx-click-away="toggle_methodology"
      >
        <div class="p-6">
          <div class="flex items-center justify-between mb-6">
            <h2 class="text-xl font-bold text-white">📊 {gettext("Cost Calculation Methodology")}</h2>
            <button phx-click="toggle_methodology" class="text-gray-400 hover:text-white">
              <.icon name="hero-x-mark" class="w-6 h-6" />
            </button>
          </div>

          <div class="space-y-6 text-gray-300">
            <%!-- Formula --%>
            <div>
              <h3 class="text-lg font-semibold text-amber-400 mb-2">{gettext("Formula")}</h3>
              <div class="bg-gray-800/50 rounded-lg p-4 font-mono text-sm">
                <p class="text-white">
                  {gettext("Total Cost")} = {gettext("Passenger Cost")} + {gettext("Operational Cost")}
                </p>
                <p class="mt-2 text-gray-400">
                  {gettext("Passenger Cost")} = {gettext("delay_hours")} × {gettext("passengers")} × 22 PLN/h
                </p>
                <p class="text-gray-400">
                  {gettext("Operational Cost")} = {gettext("delay_hours")} × (80 + 5) PLN/h
                </p>
              </div>
            </div>

            <%!-- Assumptions --%>
            <div>
              <h3 class="text-lg font-semibold text-amber-400 mb-2">{gettext("Assumptions")}</h3>
              <div class="grid gap-3">
                <div class="bg-gray-800/50 rounded-lg p-3">
                  <div class="flex justify-between">
                    <span class="text-gray-400">{gettext("Value of Time (VoT)")}</span>
                    <span class="font-semibold text-white">22 PLN/{gettext("hour")}</span>
                  </div>
                  <p class="text-xs text-gray-500 mt-1">
                    {gettext("Polish commuter weighted average")}
                  </p>
                </div>
                <div class="bg-gray-800/50 rounded-lg p-3">
                  <div class="flex justify-between">
                    <span class="text-gray-400">{gettext("Driver wage")}</span>
                    <span class="font-semibold text-white">80 PLN/{gettext("hour")}</span>
                  </div>
                  <p class="text-xs text-gray-500 mt-1">
                    {gettext("Full employer cost (incl. ZUS/taxes)")}
                  </p>
                </div>
                <div class="bg-gray-800/50 rounded-lg p-3">
                  <div class="flex justify-between">
                    <span class="text-gray-400">{gettext("Energy (idling)")}</span>
                    <span class="font-semibold text-white">5 PLN/{gettext("hour")}</span>
                  </div>
                  <p class="text-xs text-gray-500 mt-1">
                    {gettext("HVAC, lights, systems during idle")}
                  </p>
                </div>
              </div>
            </div>

            <%!-- Passenger estimates --%>
            <div>
              <h3 class="text-lg font-semibold text-amber-400 mb-2">
                {gettext("Passenger Estimates")}
              </h3>
              <div class="bg-gray-800/50 rounded-lg p-4">
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-400 text-left">
                      <th class="pb-2">{gettext("Time Period")}</th>
                      <th class="pb-2">{gettext("Hours")}</th>
                      <th class="pb-2 text-right">{gettext("Passengers")}</th>
                    </tr>
                  </thead>
                  <tbody class="text-gray-300">
                    <tr>
                      <td class="py-1">🌅 {gettext("Morning Peak")}</td>
                      <td>7:00–8:59</td>
                      <td class="text-right font-semibold text-red-400">150</td>
                    </tr>
                    <tr>
                      <td class="py-1">🌆 {gettext("Afternoon Peak")}</td>
                      <td>15:00–17:59</td>
                      <td class="text-right font-semibold text-red-400">150</td>
                    </tr>
                    <tr>
                      <td class="py-1">☀️ {gettext("Off-Peak")}</td>
                      <td>6:00–6:59, 9:00–14:59</td>
                      <td class="text-right font-semibold text-amber-400">50</td>
                    </tr>
                    <tr>
                      <td class="py-1">🌙 {gettext("Evening")}</td>
                      <td>18:00–21:59</td>
                      <td class="text-right font-semibold text-amber-400">50</td>
                    </tr>
                    <tr>
                      <td class="py-1">🌃 {gettext("Night")}</td>
                      <td>22:00–5:59</td>
                      <td class="text-right font-semibold text-gray-400">10</td>
                    </tr>
                  </tbody>
                </table>
              </div>
              <p class="text-xs text-gray-500 mt-2">
                {gettext("Based on Pesa Jazz 134N tram capacity (~240 max, ~150 comfortable)")}
              </p>
            </div>

            <%!-- Example --%>
            <div>
              <h3 class="text-lg font-semibold text-amber-400 mb-2">{gettext("Example")}</h3>
              <div class="bg-gray-800/50 rounded-lg p-4 text-sm">
                <p class="text-gray-400">{gettext("10-minute delay at 8:00 AM (peak hour):")}</p>
                <div class="mt-2 space-y-1">
                  <p>
                    {gettext("Passenger cost")}: 0.167h × 150 × 22 PLN =
                    <span class="text-red-400 font-semibold">550 PLN</span>
                  </p>
                  <p>
                    {gettext("Operational cost")}: 0.167h × 85 PLN =
                    <span class="text-amber-400 font-semibold">14 PLN</span>
                  </p>
                  <p class="border-t border-gray-700 pt-2 mt-2">
                    {gettext("Total")}: <span class="text-white font-bold">564 PLN</span>
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Leaderboard component (default sidebar state)
  defp leaderboard(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex items-baseline justify-between mb-4">
        <h2 class="text-lg font-bold text-red-400">🔥 {gettext("Top Worst Intersections")}</h2>
        <%= if @coverage_pct > 0 do %>
          <span class="text-xs text-gray-500">
            {trunc(@coverage_pct)}% {gettext("of total cost")}
          </span>
        <% end %>
      </div>

      <%= if @data == [] do %>
        <div class="text-gray-500 text-center py-8">
          {gettext("No data available for this period")}
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for {spot, idx} <- Enum.with_index(@data) do %>
            <div
              phx-click="select_intersection"
              phx-value-lat={spot.lat}
              phx-value-lon={spot.lon}
              class={"p-3 rounded-lg border cursor-pointer hover:bg-gray-800/50 transition #{severity_class(spot.severity)}"}
            >
              <div class="flex items-start justify-between">
                <div class="flex items-center gap-2">
                  <span class="text-gray-500 text-sm w-6">#{idx + 1}</span>
                  <div>
                    <div class="font-medium text-gray-200">
                      {spot.location_name || gettext("Unknown location")}
                    </div>
                    <div class="text-xs text-gray-500">
                      {spot.delay_count} {gettext("delays")} · {format_duration(spot.total_seconds)}
                    </div>
                  </div>
                </div>
                <div class="text-right">
                  <div class="font-bold text-red-400">
                    {format_cost(spot.cost.total)}
                  </div>
                  <%= if spot.multi_cycle_pct > 0 do %>
                    <div class="text-xs text-purple-400">
                      ⚡ {Float.round(spot.multi_cycle_pct, 0)}% {gettext("priority failures")}
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Report Card component (selected intersection)
  defp report_card(assigns) do
    ~H"""
    <div class="p-4">
      <button
        phx-click="deselect"
        class="text-gray-400 hover:text-white text-sm mb-4 flex items-center gap-1 cursor-pointer"
      >
        ← {gettext("Back to Leaderboard")}
      </button>

      <%!-- Location --%>
      <div class="mb-6">
        <div class="text-xs text-gray-500 uppercase tracking-wide">{gettext("Location")}</div>
        <h2 class="text-xl font-bold text-gray-200">
          📍 {@selected.location_name || gettext("Unknown")}
        </h2>
        <a
          href={"https://www.google.com/maps?q=#{@selected.lat},#{@selected.lon}"}
          target="_blank"
          class="text-xs text-gray-500 hover:text-gray-400"
        >
          {Float.round(@selected.lat, 5)}, {Float.round(@selected.lon, 5)} ↗
        </a>
      </div>

      <%!-- Stats grid --%>
      <div class="grid grid-cols-2 gap-3 mb-6">
        <div class="bg-gray-800/50 rounded-lg p-3 border border-red-900/50">
          <div class="text-2xl font-bold text-red-400">
            {format_cost(@selected.cost.total)}
          </div>
          <div class="text-xs text-gray-500">{gettext("Economic Cost")}</div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 border border-amber-900/50">
          <div class="text-2xl font-bold text-amber-400">
            {format_duration(@selected.total_seconds)}
          </div>
          <div class="text-xs text-gray-500">{gettext("Time Lost")}</div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 border border-orange-900/50">
          <div class="text-2xl font-bold text-orange-400">
            {@selected.delay_count}
          </div>
          <div class="text-xs text-gray-500">{gettext("Delays")}</div>
        </div>
        <div class="bg-gray-800/50 rounded-lg p-3 border border-purple-900/50">
          <div class="text-2xl font-bold text-purple-400">
            {@selected.multi_cycle_count}
            <span class="text-lg text-gray-500">({Float.round(@selected.multi_cycle_pct, 0)}%)</span>
          </div>
          <div class="text-xs text-gray-500">{gettext("Priority Failures")}</div>
        </div>
      </div>

      <%!-- Mini heatmap --%>
      <div class="mb-6">
        <div class="text-xs text-gray-500 uppercase tracking-wide mb-2">
          📊 {gettext("When It Fails")}
        </div>
        <.mini_heatmap heatmap={@heatmap} />
      </div>

      <%!-- Affected lines --%>
      <div class="mb-6">
        <div class="text-xs text-gray-500 uppercase tracking-wide mb-2">
          🚋 {gettext("Affected Lines")}
        </div>
        <div class="flex flex-wrap gap-2">
          <%= for line <- @selected.affected_lines do %>
            <.link
              navigate={~p"/line/#{line}"}
              class="px-2 py-1 bg-gray-800 rounded text-sm text-gray-300 hover:bg-gray-700"
            >
              {line}
            </.link>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Mini heatmap component
  defp mini_heatmap(assigns) do
    days = ["M", "T", "W", "T", "F", "S", "S"]

    assigns = assign(assigns, :days, days)

    ~H"""
    <div class="bg-gray-800/30 rounded-lg p-3">
      <div class="grid grid-cols-8 gap-1">
        <%!-- Header row --%>
        <div></div>
        <%= for day <- @days do %>
          <div class="text-gray-500 text-xs text-center font-medium">{day}</div>
        <% end %>

        <%!-- Data rows --%>
        <%= for %{hour: hour, cells: cells} <- @heatmap.grid do %>
          <div class="text-gray-500 text-xs text-right pr-1">{hour}</div>
          <%= for cell <- cells do %>
            <div
              class="w-5 h-5 rounded-sm"
              style={"background: #{heatmap_color(cell.intensity)}"}
              title={"#{cell.count} delays"}
            >
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions
  defp format_cost(amount) when is_number(amount) do
    cond do
      amount >= 1_000_000 -> "#{Float.round(amount / 1_000_000, 1)}M PLN"
      amount >= 1_000 -> "#{Float.round(amount / 1_000, 1)}k PLN"
      amount > 0 -> "#{trunc(amount)} PLN"
      true -> "0 PLN"
    end
  end

  defp format_cost(_), do: "0 PLN"

  defp format_number(n) when is_integer(n) and n >= 1000 do
    "#{div(n, 1000)}.#{rem(n, 1000) |> div(100)}k"
  end

  defp format_number(n), do: to_string(n || 0)

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{rem(seconds, 3600) |> div(60)}m"
    end
  end

  defp format_duration(_), do: "0s"

  defp severity_class(:red), do: "severity-red"
  defp severity_class(:orange), do: "severity-orange"
  defp severity_class(:yellow), do: "severity-yellow"
  defp severity_class(_), do: ""

  defp heatmap_color(intensity) when intensity > 0.8, do: "rgba(239, 68, 68, 0.9)"
  defp heatmap_color(intensity) when intensity > 0.6, do: "rgba(239, 68, 68, 0.7)"
  defp heatmap_color(intensity) when intensity > 0.4, do: "rgba(249, 115, 22, 0.6)"
  defp heatmap_color(intensity) when intensity > 0.2, do: "rgba(234, 179, 8, 0.5)"
  defp heatmap_color(intensity) when intensity > 0, do: "rgba(234, 179, 8, 0.3)"
  defp heatmap_color(_), do: "rgba(55, 65, 81, 0.3)"
end
