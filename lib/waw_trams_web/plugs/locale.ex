defmodule WawTramsWeb.Plugs.Locale do
  @moduledoc """
  Plug to set the locale based on query param, session, or default.

  ## Usage

  Add to your router pipeline:

      plug WawTramsWeb.Plugs.Locale

  Switch language by adding `?locale=pl` or `?locale=en` to any URL.
  The preference is stored in the session.
  """

  import Plug.Conn
  require Logger

  @locales ~w(en pl)
  @default_locale "en"

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = get_locale(conn)
    Gettext.put_locale(WawTramsWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> assign(:locale, locale)
  end

  defp get_locale(conn) do
    # Priority: 1. Query param, 2. Session, 3. Default
    cond do
      locale = conn.params["locale"] ->
        validate_locale(locale)

      locale = get_session(conn, :locale) ->
        validate_locale(locale)

      true ->
        @default_locale
    end
  end

  defp validate_locale(locale) when locale in @locales, do: locale
  defp validate_locale(_), do: @default_locale
end
