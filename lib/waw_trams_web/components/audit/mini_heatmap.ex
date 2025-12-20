defmodule WawTramsWeb.Components.Audit.MiniHeatmap do
  @moduledoc """
  Mini heatmap showing delay patterns by hour and day of week.
  """
  use WawTramsWeb, :html

  @doc """
  Renders a compact heatmap grid.

  ## Attributes
  - `heatmap` - Map with :grid (list of hour rows with cells) and :max_count
  """
  attr :heatmap, :map, required: true

  def mini_heatmap(assigns) do
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

  defp heatmap_color(intensity) when intensity > 0.8, do: "rgba(239, 68, 68, 0.9)"
  defp heatmap_color(intensity) when intensity > 0.6, do: "rgba(239, 68, 68, 0.7)"
  defp heatmap_color(intensity) when intensity > 0.4, do: "rgba(249, 115, 22, 0.6)"
  defp heatmap_color(intensity) when intensity > 0.2, do: "rgba(234, 179, 8, 0.5)"
  defp heatmap_color(intensity) when intensity > 0, do: "rgba(234, 179, 8, 0.3)"
  defp heatmap_color(_), do: "rgba(55, 65, 81, 0.3)"
end
