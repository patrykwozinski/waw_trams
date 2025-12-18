defmodule WawTrams.WarsawTime do
  @moduledoc """
  Helper functions for displaying times in Warsaw timezone.
  """

  @warsaw_tz "Europe/Warsaw"

  @doc """
  Converts a UTC DateTime to Warsaw time and formats it as HH:MM:SS.
  """
  def format_time(nil), do: "-"

  def format_time(%DateTime{} = utc_datetime) do
    utc_datetime
    |> to_warsaw()
    |> Calendar.strftime("%H:%M:%S")
  end

  @doc """
  Converts a UTC DateTime to Warsaw time and formats it as "Dec 18, 14:30".
  """
  def format_datetime(nil), do: "-"

  def format_datetime(%DateTime{} = utc_datetime) do
    utc_datetime
    |> to_warsaw()
    |> Calendar.strftime("%b %d, %H:%M")
  end

  @doc """
  Converts a UTC DateTime to Warsaw timezone.
  """
  def to_warsaw(%DateTime{} = utc_datetime) do
    # Use Tz database explicitly for timezone conversion
    DateTime.shift_zone!(utc_datetime, @warsaw_tz, Tz.TimeZoneDatabase)
  end

  @doc """
  Returns current time in Warsaw.
  """
  def now do
    DateTime.utc_now() |> to_warsaw()
  end

  @doc """
  Converts a UTC hour (0-23) to Warsaw hour.
  Returns the hour in Warsaw timezone based on current date's offset.
  """
  def utc_hour_to_warsaw(utc_hour) when is_integer(utc_hour) do
    # Get current offset (handles DST automatically)
    offset_seconds = current_offset_seconds()
    offset_hours = div(offset_seconds, 3600)

    rem(utc_hour + offset_hours + 24, 24)
  end

  @doc """
  Formats a UTC hour as Warsaw time range (e.g., "17:00 - 18:00").
  """
  def format_hour_range(utc_hour) when is_integer(utc_hour) do
    warsaw_hour = utc_hour_to_warsaw(utc_hour)
    next_hour = rem(warsaw_hour + 1, 24)

    "#{String.pad_leading("#{warsaw_hour}", 2, "0")}:00 - #{String.pad_leading("#{next_hour}", 2, "0")}:00"
  end

  @doc """
  Formats a UTC hour as Warsaw time (e.g., "17:00").
  """
  def format_hour(utc_hour) when is_integer(utc_hour) do
    warsaw_hour = utc_hour_to_warsaw(utc_hour)
    "#{String.pad_leading("#{warsaw_hour}", 2, "0")}:00"
  end

  @doc """
  Returns the current UTC offset for Warsaw in seconds.
  """
  def current_offset_seconds do
    now()
    |> DateTime.to_iso8601()
    |> then(fn iso ->
      # Extract offset like "+01:00" or "+02:00"
      case Regex.run(~r/([+-])(\d{2}):(\d{2})$/, iso) do
        [_, sign, hours, mins] ->
          offset = String.to_integer(hours) * 3600 + String.to_integer(mins) * 60
          if sign == "-", do: -offset, else: offset

        _ ->
          3600
      end
    end)
  end
end
