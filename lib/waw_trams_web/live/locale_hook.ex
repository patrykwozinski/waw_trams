defmodule WawTramsWeb.LocaleHook do
  @moduledoc """
  LiveView hook to set the locale from session.

  Gettext locale is process-based, so we need to set it on each LiveView mount.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  @default_locale "en"
  @locales ~w(en pl)

  def on_mount(:default, params, session, socket) do
    locale = get_locale(params, session)
    Gettext.put_locale(WawTramsWeb.Gettext, locale)

    socket =
      socket
      |> assign(:locale, locale)
      |> attach_hook(:locale_param, :handle_params, &handle_locale_param/3)

    {:cont, socket}
  end

  defp get_locale(params, session) do
    cond do
      locale = params["locale"] ->
        validate_locale(locale)

      locale = session["locale"] ->
        validate_locale(locale)

      true ->
        @default_locale
    end
  end

  defp validate_locale(locale) when locale in @locales, do: locale
  defp validate_locale(_), do: @default_locale

  # Handle locale changes via URL params during LiveView navigation
  defp handle_locale_param(params, _uri, socket) do
    if locale = params["locale"] do
      locale = validate_locale(locale)
      Gettext.put_locale(WawTramsWeb.Gettext, locale)
      {:cont, assign(socket, :locale, locale)}
    else
      {:cont, socket}
    end
  end
end
