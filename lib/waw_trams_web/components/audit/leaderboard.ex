defmodule WawTramsWeb.Components.Audit.Leaderboard do
  @moduledoc """
  Leaderboard component showing top worst intersections.
  """
  use WawTramsWeb, :html
  import WawTramsWeb.Helpers.Formatters

  @doc """
  Renders the intersection leaderboard.

  ## Attributes
  - `data` - List of intersection data maps
  - `coverage_pct` - Percentage of total cost represented by leaderboard
  """
  attr :data, :list, required: true
  attr :coverage_pct, :float, required: true

  def leaderboard(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex items-baseline justify-between mb-4">
        <h2 class="text-lg font-bold text-gray-200">🔥 {gettext("Top Worst Intersections")}</h2>
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
        <div class="space-y-1.5">
          <%= for {spot, idx} <- Enum.with_index(@data) do %>
            <div
              phx-click="select_intersection"
              phx-value-lat={spot.lat}
              phx-value-lon={spot.lon}
              class={[
                "p-2.5 rounded-lg border cursor-pointer hover:bg-gray-800/50 transition",
                if(idx < 3, do: "border-gray-700 bg-gray-800/30", else: "border-gray-800/50 bg-transparent")
              ]}
            >
              <div class="flex items-center justify-between gap-3">
                <div class="flex items-center gap-2 min-w-0">
                  <span class={[
                    "text-sm font-medium w-5 flex-shrink-0",
                    if(idx < 3, do: "text-red-400", else: "text-gray-600")
                  ]}>
                    {idx + 1}
                  </span>
                  <div class="min-w-0">
                    <div class="font-medium text-gray-300 text-sm truncate">
                      {spot.location_name || gettext("Unknown location")}
                    </div>
                    <div class="text-xs text-gray-500">
                      {spot.delay_count} {gettext("delays")} · {format_duration(spot.total_seconds)}
                    </div>
                  </div>
                </div>
                <div class={[
                  "font-semibold text-sm flex-shrink-0",
                  if(idx < 3, do: "text-red-400", else: "text-gray-400")
                ]}>
                  {format_cost(spot.cost.total)}
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
