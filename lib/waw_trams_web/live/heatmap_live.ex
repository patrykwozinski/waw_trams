defmodule WawTramsWeb.HeatmapLive do
  use WawTramsWeb, :live_view

  alias WawTrams.DelayEvent

  @day_names %{
    1 => "Mon",
    2 => "Tue",
    3 => "Wed",
    4 => "Thu",
    5 => "Fri",
    6 => "Sat",
    7 => "Sun"
  }

  def mount(_params, _session, socket) do
    # Default to last 7 days
    heatmap = DelayEvent.heatmap_grid(since: DateTime.add(DateTime.utc_now(), -7, :day))

    {:ok,
     socket
     |> assign(:heatmap, heatmap)
     |> assign(:period, "7d")
     |> assign(:day_names, @day_names)}
  end

  def handle_event("change_period", %{"period" => period}, socket) do
    since = period_to_since(period)
    heatmap = DelayEvent.heatmap_grid(since: since)

    {:noreply,
     socket
     |> assign(:heatmap, heatmap)
     |> assign(:period, period)}
  end

  defp period_to_since("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  defp period_to_since("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp period_to_since("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp period_to_since(_), do: DateTime.add(DateTime.utc_now(), -7, :day)

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-slate-900 via-slate-800 to-slate-900 text-white">
      <div class="max-w-[1600px] mx-auto px-6 py-8">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-transparent bg-clip-text bg-gradient-to-r from-amber-400 to-orange-500">
              📊 Delay Heatmap
            </h1>
            <p class="text-slate-400 mt-1">When do delays happen most?</p>
          </div>

          <div class="flex items-center gap-4">
            <%!-- Period selector --%>
            <form phx-change="change_period" class="flex gap-2">
              <select
                name="period"
                class="bg-slate-700 border border-slate-600 rounded-lg px-4 py-2 text-white focus:ring-2 focus:ring-amber-500"
              >
                <option value="24h" selected={@period == "24h"}>Last 24 hours</option>
                <option value="7d" selected={@period == "7d"}>Last 7 days</option>
                <option value="30d" selected={@period == "30d"}>Last 30 days</option>
              </select>
            </form>

            <.link navigate={~p"/dashboard"} class="text-slate-400 hover:text-white transition-colors">
              ← Back to Dashboard
            </.link>
          </div>
        </div>

        <%!-- Stats summary --%>
        <div class="grid grid-cols-3 gap-6 mb-8">
          <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
            <div class="text-3xl font-bold text-amber-400">{@heatmap.total_delays}</div>
            <div class="text-slate-400 text-sm">Total Delays</div>
          </div>
          <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
            <div class="text-3xl font-bold text-orange-400">{@heatmap.max_count}</div>
            <div class="text-slate-400 text-sm">Peak Hour Max</div>
          </div>
          <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
            <div class="text-3xl font-bold text-red-400">
              {find_worst_slot(@heatmap.grid, @day_names)}
            </div>
            <div class="text-slate-400 text-sm">Worst Time Slot</div>
          </div>
        </div>

        <%!-- Heatmap Grid --%>
        <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700 overflow-x-auto">
          <h2 class="text-xl font-semibold mb-4 text-white">Hour × Day of Week</h2>

          <div class="inline-block">
            <%!-- Column headers (days) --%>
            <div class="flex mb-2">
              <div class="w-16"></div>
              <%= for day <- 1..7 do %>
                <div class={[
                  "w-20 text-center text-sm font-medium",
                  if(day in [6, 7], do: "text-amber-400", else: "text-slate-300")
                ]}>
                  {@day_names[day]}
                </div>
              <% end %>
            </div>

            <%!-- Rows (hours) --%>
            <%= for row <- @heatmap.grid do %>
              <div class="flex items-center mb-1">
                <%!-- Hour label --%>
                <div class="w-16 text-right pr-4 text-sm text-slate-400 font-mono">
                  {format_hour(row.hour)}
                </div>

                <%!-- Cells --%>
                <%= for cell <- row.cells do %>
                  <div
                    class="w-20 h-12 mx-0.5 rounded-md flex items-center justify-center text-xs font-medium transition-all hover:scale-105 cursor-default"
                    style={cell_style(cell.intensity)}
                    title={"#{@day_names[cell.day]} #{format_hour(cell.hour)}: #{cell.count} delays (#{format_duration(cell.total)})"}
                  >
                    <%= if cell.count > 0 do %>
                      <span class={if cell.intensity > 0.5, do: "text-white", else: "text-slate-300"}>
                        {cell.count}
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Legend --%>
          <div class="mt-6 flex items-center gap-4 text-sm text-slate-400">
            <span>Fewer delays</span>
            <div class="flex gap-1">
              <div class="w-8 h-4 rounded" style="background: rgb(30, 41, 59);"></div>
              <div class="w-8 h-4 rounded" style="background: rgb(120, 90, 30);"></div>
              <div class="w-8 h-4 rounded" style="background: rgb(180, 100, 20);"></div>
              <div class="w-8 h-4 rounded" style="background: rgb(220, 80, 20);"></div>
              <div class="w-8 h-4 rounded" style="background: rgb(200, 30, 30);"></div>
            </div>
            <span>More delays</span>
          </div>
        </div>

        <%!-- Insights --%>
        <div class="mt-8 grid grid-cols-2 gap-6">
          <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
            <h3 class="text-lg font-semibold mb-4 text-white">🌅 Morning Rush</h3>
            <p class="text-slate-400 text-sm">
              {morning_insight(@heatmap.grid)}
            </p>
          </div>
          <div class="bg-slate-800/50 rounded-xl p-6 border border-slate-700">
            <h3 class="text-lg font-semibold mb-4 text-white">🌆 Evening Rush</h3>
            <p class="text-slate-400 text-sm">
              {evening_insight(@heatmap.grid)}
            </p>
          </div>
        </div>

        <%!-- Navigation --%>
        <div class="mt-8 flex justify-center gap-4">
          <.link
            navigate={~p"/map"}
            class="px-6 py-3 bg-slate-700 hover:bg-slate-600 rounded-lg transition-colors"
          >
            🗺️ View Map
          </.link>
          <.link
            navigate={~p"/line"}
            class="px-6 py-3 bg-slate-700 hover:bg-slate-600 rounded-lg transition-colors"
          >
            🚋 Line Analysis
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # Generate CSS style for cell based on intensity (0.0 - 1.0)
  defp cell_style(0), do: "background: rgb(30, 41, 59);"

  defp cell_style(intensity) do
    # Gradient from dark slate -> amber -> orange -> red
    cond do
      intensity < 0.25 ->
        "background: rgb(#{round(30 + 90 * intensity * 4)}, #{round(41 + 49 * intensity * 4)}, #{round(59 - 29 * intensity * 4)});"

      intensity < 0.5 ->
        "background: rgb(#{round(120 + 60 * (intensity - 0.25) * 4)}, #{round(90 + 10 * (intensity - 0.25) * 4)}, #{round(30 - 10 * (intensity - 0.25) * 4)});"

      intensity < 0.75 ->
        "background: rgb(#{round(180 + 40 * (intensity - 0.5) * 4)}, #{round(100 - 20 * (intensity - 0.5) * 4)}, #{round(20)});"

      true ->
        "background: rgb(#{round(220 - 20 * (intensity - 0.75) * 4)}, #{round(80 - 50 * (intensity - 0.75) * 4)}, #{round(20 + 10 * (intensity - 0.75) * 4)});"
    end
  end

  defp format_hour(hour) do
    "#{String.pad_leading(to_string(hour), 2, "0")}:00"
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) do
    minutes = div(seconds, 60)
    "#{minutes}m"
  end

  defp find_worst_slot(grid, day_names) do
    worst =
      grid
      |> Enum.flat_map(fn row -> row.cells end)
      |> Enum.max_by(& &1.count, fn -> %{day: 1, hour: 0, count: 0} end)

    if worst.count > 0 do
      "#{day_names[worst.day]} #{format_hour(worst.hour)}"
    else
      "No data"
    end
  end

  defp morning_insight(grid) do
    morning_delays =
      grid
      |> Enum.filter(fn row -> row.hour >= 6 and row.hour <= 9 end)
      |> Enum.flat_map(fn row -> row.cells end)
      |> Enum.map(& &1.count)
      |> Enum.sum()

    peak_hour =
      grid
      |> Enum.filter(fn row -> row.hour >= 6 and row.hour <= 9 end)
      |> Enum.max_by(fn row -> Enum.sum(Enum.map(row.cells, & &1.count)) end, fn -> %{hour: 0} end)

    "#{morning_delays} delays between 6:00-10:00. Peak at #{format_hour(peak_hour.hour)}."
  end

  defp evening_insight(grid) do
    evening_delays =
      grid
      |> Enum.filter(fn row -> row.hour >= 15 and row.hour <= 19 end)
      |> Enum.flat_map(fn row -> row.cells end)
      |> Enum.map(& &1.count)
      |> Enum.sum()

    peak_hour =
      grid
      |> Enum.filter(fn row -> row.hour >= 15 and row.hour <= 19 end)
      |> Enum.max_by(fn row -> Enum.sum(Enum.map(row.cells, & &1.count)) end, fn -> %{hour: 0} end)

    "#{evening_delays} delays between 15:00-20:00. Peak at #{format_hour(peak_hour.hour)}."
  end
end
