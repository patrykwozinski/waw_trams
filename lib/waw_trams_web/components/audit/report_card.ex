defmodule WawTramsWeb.Components.Audit.ReportCard do
  @moduledoc """
  Report card showing details for a selected intersection.
  """
  use WawTramsWeb, :html
  import WawTramsWeb.Helpers.Formatters
  alias WawTramsWeb.Components.Audit.MiniHeatmap

  @doc """
  Renders the intersection report card with stats and heatmap.

  ## Attributes
  - `selected` - The selected intersection data
  - `heatmap` - Heatmap data for the intersection
  """
  attr :selected, :map, required: true
  attr :heatmap, :map, required: true

  def report_card(assigns) do
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

      <%!-- Stats --%>
      <div class="grid grid-cols-3 gap-3 mb-6">
        <div class="bg-gray-800/50 rounded-lg p-3 border border-red-900/50">
          <div class="text-2xl font-bold text-red-400">
            {format_cost(@selected.cost.total)}
          </div>
          <div class="text-xs text-gray-500">{gettext("Cost")}</div>
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
      </div>

      <%!-- Mini heatmap --%>
      <div class="mb-6">
        <div class="text-xs text-gray-500 uppercase tracking-wide mb-2">
          📊 {gettext("When It Fails")}
        </div>
        <MiniHeatmap.mini_heatmap heatmap={@heatmap} />
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
end
