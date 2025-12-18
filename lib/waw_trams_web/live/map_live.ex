defmodule WawTramsWeb.MapLive do
  use WawTramsWeb, :live_view

  alias WawTrams.DelayEvent

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_event("request_hot_spots", _params, socket) do
    hot_spots = DelayEvent.hot_spots(limit: 20)
    {:noreply, push_event(socket, "hot_spots", %{spots: hot_spots})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
    <link rel="stylesheet" href="https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css" />
    <style>.marker-cluster-custom { background: transparent !important; }</style>
    <div class="h-screen flex flex-col bg-gray-950 text-gray-100">
      <%!-- Header --%>
      <div class="px-6 py-4 bg-gray-900 border-b border-gray-800 flex items-center justify-between">
        <div>
          <h1 class="text-xl font-bold text-amber-400">🗺️ Hot Spot Map</h1>
          <p class="text-gray-500 text-sm">Intersection delays (24h)</p>
        </div>
        <.link navigate={~p"/dashboard"} class="text-gray-400 hover:text-white text-sm">
          ← Back to Dashboard
        </.link>
      </div>

      <%!-- Map Container --%>
      <div
        id="map"
        phx-hook="MapHook"
        phx-update="ignore"
        class="flex-1 w-full"
      >
      </div>

      <%!-- Legend --%>
      <div class="px-6 py-3 bg-gray-900 border-t border-gray-800 flex items-center gap-6 text-sm">
        <span class="text-gray-500">Marker size = delay count</span>
        <div class="flex items-center gap-4">
          <div class="flex items-center gap-2">
            <span class="w-3 h-3 rounded-full bg-red-500"></span>
            <span class="text-gray-400">Top 3</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-3 h-3 rounded-full bg-orange-500"></span>
            <span class="text-gray-400">4-7</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-3 h-3 rounded-full bg-yellow-500"></span>
            <span class="text-gray-400">8+</span>
          </div>
        </div>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  defp flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="fixed top-4 right-4 z-50" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
