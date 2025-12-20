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

  @doc "Format seconds as human-readable duration"
  def format_duration(seconds) when is_integer(seconds) do
    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h #{rem(seconds, 3600) |> div(60)}m"
    end
  end

  def format_duration(_), do: "0s"

  @doc "Format datetime as time string"
  def format_time(nil), do: "-"

  def format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  @doc "Format duration in minutes as hours/minutes"
  def format_time_lost(minutes) when minutes < 60, do: "#{minutes}m"

  def format_time_lost(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}h #{mins}m"
  end

  @doc "Format datetime as relative time ago"
  def time_ago(nil), do: "-"

  def time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end
end
