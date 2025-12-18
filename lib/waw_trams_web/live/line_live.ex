defmodule WawTramsWeb.LineLive do
  use WawTramsWeb, :live_view

  alias WawTrams.DelayEvent

  @impl true
  def mount(%{"line" => line}, _session, socket) do
    {:ok, load_line_data(socket, line)}
  end

  def mount(_params, _session, socket) do
    available_lines = DelayEvent.lines_with_delays()

    {:ok,
     socket
     |> assign(:line, nil)
     |> assign(:available_lines, available_lines)
     |> assign(:hours_data, [])
     |> assign(:summary, nil)}
  end

  @impl true
  def handle_params(%{"line" => line}, _uri, socket) do
    {:noreply, load_line_data(socket, line)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_line", %{"line" => line}, socket) do
    {:noreply, push_patch(socket, to: ~p"/line/#{line}")}
  end

  defp load_line_data(socket, line) do
    hours_data = DelayEvent.delays_by_hour(line)
    summary = DelayEvent.line_summary(line)
    available_lines = DelayEvent.lines_with_delays()

    socket
    |> assign(:line, line)
    |> assign(:available_lines, available_lines)
    |> assign(:hours_data, hours_data)
    |> assign(:summary, summary)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-[1600px] mx-auto px-6 py-8">
          <%!-- Header --%>
          <div class="mb-8">
            <h1 class="text-3xl font-bold text-amber-400 tracking-tight">
              🚋 Line Analysis
            </h1>
            <p class="text-gray-400 mt-1">
              Find the worst times to travel on a specific tram line
            </p>
          </div>

          <%!-- Line Selector --%>
          <div class="mb-8">
            <form phx-change="select_line" class="flex items-center gap-4">
              <label class="text-gray-400">Select line:</label>
              <select
                name="line"
                class="bg-gray-800 border border-gray-700 rounded-lg px-4 py-2 text-amber-300 font-mono text-lg focus:ring-amber-500 focus:border-amber-500"
              >
                <option value="">Choose a line...</option>
                <%= for l <- @available_lines do %>
                  <option value={l} selected={@line == l}><%= l %></option>
                <% end %>
              </select>
            </form>
          </div>

          <%= if @line do %>
            <%!-- Summary Card --%>
            <div class="bg-gray-900 rounded-xl border border-gray-800 p-6 mb-8">
              <div class="flex items-center gap-4 mb-4">
                <span class="px-4 py-2 bg-amber-500/20 text-amber-300 rounded-lg font-mono text-2xl font-bold">
                  <%= @line %>
                </span>
                <div>
                  <h2 class="text-xl font-semibold">Line <%= @line %> Summary</h2>
                  <p class="text-gray-500 text-sm">Last 7 days</p>
                </div>
              </div>

              <%= if @summary do %>
                <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
                  <div class="bg-gray-800/50 rounded-lg p-4">
                    <div class="text-2xl font-bold text-orange-400"><%= @summary.total_delays %></div>
                    <div class="text-gray-500 text-sm">Total Delays</div>
                  </div>
                  <div class="bg-gray-800/50 rounded-lg p-4">
                    <div class="text-2xl font-bold text-red-400"><%= @summary.blockage_count || 0 %></div>
                    <div class="text-gray-500 text-sm">Blockages</div>
                  </div>
                  <div class="bg-gray-800/50 rounded-lg p-4">
                    <div class="text-2xl font-bold text-amber-400"><%= format_duration(@summary.total_seconds) %></div>
                    <div class="text-gray-500 text-sm">Total Time Lost</div>
                  </div>
                  <div class="bg-gray-800/50 rounded-lg p-4">
                    <div class="text-2xl font-bold text-gray-300"><%= @summary.avg_seconds %>s</div>
                    <div class="text-gray-500 text-sm">Avg Delay</div>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Worst Hours Table --%>
            <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-800">
                <h2 class="font-semibold text-lg">⏰ Delays by Hour</h2>
                <p class="text-gray-500 text-sm mt-1">Sorted by total delay time (worst first)</p>
              </div>

              <%= if @hours_data == [] do %>
                <div class="p-8 text-center text-gray-500">
                  No delay data recorded for Line <%= @line %> yet.
                  <br />
                  <span class="text-sm">Check back after running for a few days.</span>
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="w-full text-sm">
                    <thead class="bg-gray-800/50">
                      <tr class="text-left text-gray-400">
                        <th class="px-5 py-3 font-medium">Hour</th>
                        <th class="px-5 py-3 font-medium">Delays</th>
                        <th class="px-5 py-3 font-medium">Blockages</th>
                        <th class="px-5 py-3 font-medium">Total Time</th>
                        <th class="px-5 py-3 font-medium">Avg</th>
                        <th class="px-5 py-3 font-medium">At Intersection</th>
                        <th class="px-5 py-3 font-medium"></th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-800">
                      <% sorted_hours = Enum.sort_by(@hours_data, & &1.hour) %>
                      <% worst_hour = Enum.max_by(@hours_data, & &1.total_seconds).hour %>
                      <%= for hour_data <- sorted_hours do %>
                        <tr class={["hover:bg-gray-800/50", hour_data.hour == worst_hour && "bg-red-500/10"]}>
                          <td class="px-5 py-3">
                            <span class="font-mono text-gray-200">
                              <%= String.pad_leading("#{hour_data.hour}", 2, "0") %>:00 - <%= String.pad_leading("#{hour_data.hour + 1}", 2, "0") %>:00
                            </span>
                          </td>
                          <td class="px-5 py-3">
                            <span class="text-orange-400 font-semibold"><%= hour_data.delay_count %></span>
                          </td>
                          <td class="px-5 py-3">
                            <span class="text-red-400"><%= hour_data.blockage_count %></span>
                          </td>
                          <td class="px-5 py-3">
                            <span class="text-amber-400"><%= format_duration(hour_data.total_seconds) %></span>
                          </td>
                          <td class="px-5 py-3 text-gray-400">
                            <%= hour_data.avg_seconds %>s
                          </td>
                          <td class="px-5 py-3 text-gray-400">
                            <%= hour_data.intersection_delays %>
                          </td>
                          <td class="px-5 py-3">
                            <%= if hour_data.hour == worst_hour do %>
                              <span class="px-2 py-1 bg-red-500/20 text-red-400 rounded text-xs font-medium">
                                WORST
                              </span>
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>

            <%!-- Visual Bar Chart --%>
            <%= if @hours_data != [] do %>
              <div class="mt-8 bg-gray-900 rounded-xl border border-gray-800 p-6">
                <h3 class="font-semibold mb-4">📊 Delay Distribution</h3>
                <div class="space-y-2">
                  <% max_seconds = Enum.max_by(@hours_data, & &1.total_seconds).total_seconds %>
                  <% sorted_by_hour = Enum.sort_by(@hours_data, & &1.hour) %>
                  <%= for hour_data <- sorted_by_hour do %>
                    <% width = if max_seconds > 0, do: hour_data.total_seconds / max_seconds * 100, else: 0 %>
                    <div class="flex items-center gap-3">
                      <span class="w-16 text-gray-500 text-sm font-mono">
                        <%= String.pad_leading("#{hour_data.hour}", 2, "0") %>:00
                      </span>
                      <div class="flex-1 bg-gray-800 rounded-full h-4 overflow-hidden">
                        <div
                          class={[
                            "h-full rounded-full transition-all",
                            bar_color(hour_data.total_seconds, max_seconds)
                          ]}
                          style={"width: #{width}%"}
                        >
                        </div>
                      </div>
                      <span class="w-20 text-right text-gray-400 text-sm">
                        <%= format_duration(hour_data.total_seconds) %>
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% else %>
            <%!-- No line selected --%>
            <div class="bg-gray-900 rounded-xl border border-gray-800 p-12 text-center">
              <div class="text-6xl mb-4">🚋</div>
              <p class="text-gray-400">Select a tram line to see delay analysis</p>
            </div>
          <% end %>

          <%!-- Back link --%>
          <div class="mt-8 text-center">
            <.link navigate={~p"/dashboard"} class="text-gray-500 hover:text-white text-sm">
              ← Back to Dashboard
            </.link>
          </div>
        </div>
      </div>
    """
  end

  # Helper functions

  defp format_duration(nil), do: "-"
  defp format_duration(0), do: "0s"
  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end
  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end

  defp bar_color(seconds, max) when max > 0 do
    ratio = seconds / max
    cond do
      ratio > 0.8 -> "bg-red-500"
      ratio > 0.5 -> "bg-orange-500"
      ratio > 0.3 -> "bg-amber-500"
      true -> "bg-green-500"
    end
  end
  defp bar_color(_, _), do: "bg-gray-600"
end
