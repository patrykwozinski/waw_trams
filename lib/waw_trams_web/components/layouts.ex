defmodule WawTramsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use WawTramsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shared header for all pages with navigation.
  """
  attr :active, :atom, default: nil, doc: "the active page (:audit, :dashboard, :line)"

  def site_header(assigns) do
    ~H"""
    <header class="bg-gray-900 border-b border-gray-800 px-4 md:px-6 py-3">
      <div class="flex items-center justify-between max-w-[1600px] mx-auto">
        <a href="/" class="flex items-center gap-2 group">
          <span class="text-2xl">🚋</span>
          <span class="font-bold text-white group-hover:text-amber-400 transition-colors hidden sm:inline">
            Warsaw Tram Auditor
          </span>
        </a>

        <nav class="flex items-center gap-2 md:gap-4">
          <.link
            navigate="/"
            class={[
              "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
              @active == :audit && "bg-red-500/20 text-red-400",
              @active != :audit && "text-gray-400 hover:text-white hover:bg-gray-800"
            ]}
          >
            <span class="hidden md:inline">🚨</span> {gettext("Audit")}
          </.link>
          <.link
            navigate="/dashboard"
            class={[
              "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
              @active == :dashboard && "bg-amber-500/20 text-amber-400",
              @active != :dashboard && "text-gray-400 hover:text-white hover:bg-gray-800"
            ]}
          >
            <span class="hidden md:inline">📊</span> {gettext("Dashboard")}
          </.link>
          <.link
            navigate="/line"
            class={[
              "px-3 py-1.5 rounded-lg text-sm font-medium transition-colors",
              @active == :line && "bg-amber-500/20 text-amber-400",
              @active != :line && "text-gray-400 hover:text-white hover:bg-gray-800"
            ]}
          >
            <span class="hidden md:inline">🚋</span> {gettext("By Line")}
          </.link>

          <%!-- Language Switcher --%>
          <div class="flex gap-1 bg-gray-800 rounded-lg p-1 ml-2">
            <a
              href="?locale=en"
              class={[
                "px-2 py-1 rounded text-xs font-medium transition-colors",
                Gettext.get_locale(WawTramsWeb.Gettext) == "en" && "bg-amber-500 text-gray-900",
                Gettext.get_locale(WawTramsWeb.Gettext) != "en" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              EN
            </a>
            <a
              href="?locale=pl"
              class={[
                "px-2 py-1 rounded text-xs font-medium transition-colors",
                Gettext.get_locale(WawTramsWeb.Gettext) == "pl" && "bg-amber-500 text-gray-900",
                Gettext.get_locale(WawTramsWeb.Gettext) != "pl" && "text-gray-400 hover:text-gray-200"
              ]}
            >
              PL
            </a>
          </div>
        </nav>
      </div>
    </header>
    """
  end

  @doc """
  Shared footer for all pages.
  """
  def site_footer(assigns) do
    ~H"""
    <footer class="bg-gray-900 border-t border-gray-800 py-4 px-4 md:px-6">
      <div class="max-w-[1600px] mx-auto flex flex-col md:flex-row items-center justify-between gap-2 text-sm text-gray-500">
        <div>
          {gettext("Data source")}: GTFS-RT via mkuran.pl • {gettext("Polling every 10s")}
        </div>
        <div class="flex items-center gap-4">
          <a
            href="https://github.com/patrykwozinski/waw_trams"
            target="_blank"
            class="hover:text-white transition-colors"
          >
            GitHub
          </a>
        </div>
      </div>
    </footer>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
