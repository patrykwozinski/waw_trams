defmodule WawTramsWeb.Helpers.Formatters do
  @moduledoc """
  Shared formatting helpers for cost, duration, and numbers.
  """

  @doc "Format cost amount as PLN with k/M suffix"
  def format_cost(amount) when is_number(amount) do
    cond do
      amount >= 1_000_000 -> "#{Float.round(amount / 1_000_000, 1)}M PLN"
      amount >= 1_000 -> "#{Float.round(amount / 1_000, 1)}k PLN"
      amount > 0 -> "#{trunc(amount)} PLN"
      true -> "0 PLN"
    end
  end

  def format_cost(_), do: "0 PLN"

  @doc "Format large numbers with k suffix"
  def format_number(n) when is_integer(n) and n >= 1000 do
    "#{div(n, 1000)}.#{rem(n, 1000) |> div(100)}k"
  end

  def format_number(n), do: to_string(n || 0)

  @doc """
  Format seconds as human-readable duration.

  Options:
  - `:compact` (default) - "5m", "2h 30m"
  - `:detailed` - "5m 30s", "2h 30m"
  """
  def format_duration(seconds, opts \\ [])
  def format_duration(nil, _opts), do: "-"
  def format_duration(0, _opts), do: "0s"

  def format_duration(seconds, opts) when is_integer(seconds) do
    detailed = Keyword.get(opts, :detailed, false)

    cond do
      seconds < 60 ->
        "#{seconds}s"

      seconds < 3600 ->
        mins = div(seconds, 60)
        secs = rem(seconds, 60)
        if detailed and secs > 0, do: "#{mins}m #{secs}s", else: "#{mins}m"

      true ->
        hours = div(seconds, 3600)
        mins = div(rem(seconds, 3600), 60)
        "#{hours}h #{mins}m"
    end
  end

  def format_duration(_, _opts), do: "0s"

  @doc "Format duration in minutes as hours/minutes"
  def format_time_lost(minutes) when is_integer(minutes) and minutes < 60, do: "#{minutes}m"

  def format_time_lost(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}h #{mins}m"
  end

  def format_time_lost(_), do: "0m"

  @doc "Format datetime as relative time ago"
  def time_ago(nil), do: "-"

  def time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  @doc "Format duration since a given datetime"
  def duration_since(nil), do: "-"

  def duration_since(started_at) do
    seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
    format_duration(seconds, detailed: true)
  end
end
