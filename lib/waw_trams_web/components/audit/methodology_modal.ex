defmodule WawTramsWeb.Components.Audit.MethodologyModal do
  @moduledoc """
  Modal explaining the cost calculation methodology.
  """
  use WawTramsWeb, :html

  @doc """
  Renders the methodology modal explaining how costs are calculated.

  ## Attributes
  - No attributes required, self-contained component
  """
  attr :rest, :global

  def methodology_modal(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-[1000] flex items-center justify-center bg-black/70"
      phx-click="toggle_methodology"
      {@rest}
    >
      <div
        class="bg-gray-900 border border-gray-700 rounded-xl max-w-xl w-full mx-4 max-h-[90vh] overflow-y-auto"
        phx-click-away="toggle_methodology"
      >
        <div class="p-5">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-bold text-white">📊 {gettext("How We Calculate Cost")}</h2>
            <button phx-click="toggle_methodology" class="text-gray-400 hover:text-white cursor-pointer">
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <div class="space-y-4 text-gray-300 text-sm">
            <%!-- What is a delay --%>
            <div class="bg-orange-500/10 border border-orange-500/30 rounded-lg p-3">
              <div class="font-semibold text-orange-400 mb-1">{gettext("What is a delay?")}</div>
              <p class="text-gray-300">
                {gettext("Tram stopped >30 seconds away from any platform.")}
              </p>
              <p class="text-xs text-gray-500 mt-1">
                {gettext("We ignore platform stops, terminals, and stops under 30s.")}
              </p>
            </div>

            <%!-- Formula --%>
            <div>
              <div class="font-semibold text-amber-400 mb-2">{gettext("Cost Formula")}</div>
              <div class="bg-gray-800/50 rounded-lg p-3 space-y-3">
                <div>
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-red-400 font-medium">{gettext("Passenger Time")}</span>
                    <span class="text-gray-500">=</span>
                    <span class="text-gray-400 text-xs">
                      {gettext("hours")} × {gettext("passengers")} × 22 PLN/h
                    </span>
                  </div>
                  <p class="text-xs text-gray-500 ml-4">
                    {gettext("22 PLN/h = value of commuter time (Polish studies)")}
                  </p>
                </div>
                <div>
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-amber-400 font-medium">{gettext("Operations")}</span>
                    <span class="text-gray-500">=</span>
                    <span class="text-gray-400 text-xs">{gettext("hours")} × 85 PLN/h</span>
                  </div>
                  <p class="text-xs text-gray-500 ml-4">
                    {gettext("Driver wage")}: 80 PLN/h • {gettext("Energy (HVAC, systems)")}: 5 PLN/h
                  </p>
                </div>
              </div>
            </div>

            <%!-- Passengers per time --%>
            <div>
              <div class="font-semibold text-amber-400 mb-2">{gettext("Passengers per Tram")}</div>
              <div class="grid grid-cols-2 gap-2 text-xs">
                <div class="bg-gray-800/50 rounded p-2 flex justify-between">
                  <span>🌅 {gettext("Rush")} <span class="text-gray-500">7–9, 15–18</span></span>
                  <span class="text-red-400 font-semibold">150</span>
                </div>
                <div class="bg-gray-800/50 rounded p-2 flex justify-between">
                  <span>☀️ {gettext("Day")} <span class="text-gray-500">6–7, 9–15</span></span>
                  <span class="text-amber-400 font-semibold">50</span>
                </div>
                <div class="bg-gray-800/50 rounded p-2 flex justify-between">
                  <span>🌙 {gettext("Evening")} <span class="text-gray-500">18–22</span></span>
                  <span class="text-amber-400 font-semibold">50</span>
                </div>
                <div class="bg-gray-800/50 rounded p-2 flex justify-between">
                  <span>🌃 {gettext("Night")} <span class="text-gray-500">22–6</span></span>
                  <span class="text-gray-400 font-semibold">10</span>
                </div>
              </div>
            </div>

            <%!-- Example --%>
            <div class="bg-amber-500/10 border border-amber-500/30 rounded-lg p-3">
              <div class="font-semibold text-amber-400 mb-1">💡 {gettext("Example")}</div>
              <p class="text-gray-300 mb-2">{gettext("5 min delay during morning rush:")}</p>
              <div class="font-mono text-xs">
                <span class="text-gray-400">(0.08h × 150 × 22) + (0.08h × 85) =</span>
                <span class="text-white font-bold ml-1">271 PLN</span>
              </div>
            </div>

            <%!-- Sources --%>
            <p class="text-xs text-gray-500 text-center">
              {gettext("Value of Time: Polish commuter studies")} • {gettext("Capacity: Pesa Jazz 134N")}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

end
