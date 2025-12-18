defmodule WawTrams.DailyLineStat do
  @moduledoc """
  Daily aggregated statistics per tram line.

  Includes hourly breakdown in `by_hour` field for time-of-day analysis.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias WawTrams.Repo

  schema "daily_line_stats" do
    field :date, :date
    field :line, :string
    field :delay_count, :integer, default: 0
    field :blockage_count, :integer, default: 0
    field :total_seconds, :integer, default: 0
    field :intersection_count, :integer, default: 0
    field :by_hour, :map, default: %{}

    timestamps()
  end

  @required_fields ~w(date line)a
  @optional_fields ~w(delay_count blockage_count total_seconds intersection_count by_hour)a

  def changeset(stat, attrs) do
    stat
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

  @doc """
  Returns most impacted lines for a date range using aggregated data.
  """
  def impacted_lines(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))
    limit = Keyword.get(opts, :limit, 10)

    from(s in __MODULE__,
      where: s.date >= ^since,
      group_by: s.line,
      select: %{
        line: s.line,
        delay_count: sum(s.delay_count),
        blockage_count: sum(s.blockage_count),
        total_seconds: sum(s.total_seconds),
        intersection_count: sum(s.intersection_count)
      },
      order_by: [desc: sum(s.total_seconds)],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        line: row.line,
        delay_count: row.delay_count,
        blockage_count: row.blockage_count,
        total_seconds: row.total_seconds || 0,
        avg_seconds: safe_div(row.total_seconds, row.delay_count + row.blockage_count)
      }
    end)
  end

  @doc """
  Returns delays by hour for a specific line, aggregated from daily stats.
  """
  def delays_by_hour(line, opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))

    stats =
      from(s in __MODULE__,
        where: s.date >= ^since and s.line == ^line,
        select: s.by_hour
      )
      |> Repo.all()

    # Merge all by_hour maps
    stats
    |> Enum.reduce(%{}, fn by_hour, acc ->
      Map.merge(acc, by_hour || %{}, fn _k, v1, v2 ->
        merge_hour_stats(v1, v2)
      end)
    end)
    |> Enum.map(fn {hour, stats} ->
      %{
        hour: String.to_integer(hour),
        delay_count: stats["delay_count"] || 0,
        blockage_count: stats["blockage_count"] || 0,
        total_seconds: stats["total_seconds"] || 0,
        avg_seconds:
          safe_div(
            stats["total_seconds"],
            (stats["delay_count"] || 0) + (stats["blockage_count"] || 0)
          ),
        intersection_delays: stats["intersection_delays"] || 0
      }
    end)
    |> Enum.sort_by(& &1.hour)
  end

  defp merge_hour_stats(s1, s2) when is_map(s1) and is_map(s2) do
    %{
      "delay_count" => (s1["delay_count"] || 0) + (s2["delay_count"] || 0),
      "blockage_count" => (s1["blockage_count"] || 0) + (s2["blockage_count"] || 0),
      "total_seconds" => (s1["total_seconds"] || 0) + (s2["total_seconds"] || 0),
      "intersection_delays" => (s1["intersection_delays"] || 0) + (s2["intersection_delays"] || 0)
    }
  end

  defp merge_hour_stats(s1, _s2), do: s1

  @doc """
  Returns line summary for a date range.
  """
  def line_summary(line, opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))

    from(s in __MODULE__,
      where: s.date >= ^since and s.line == ^line,
      select: %{
        total_delays: sum(s.delay_count),
        total_blockages: sum(s.blockage_count),
        total_seconds: sum(s.total_seconds),
        intersection_count: sum(s.intersection_count)
      }
    )
    |> Repo.one()
    |> then(fn
      nil ->
        %{
          total_delays: 0,
          total_blockages: 0,
          total_seconds: 0,
          intersection_count: 0,
          avg_seconds: 0
        }

      result ->
        total = (result.total_delays || 0) + (result.total_blockages || 0)

        %{
          total_delays: result.total_delays || 0,
          blockage_count: result.total_blockages || 0,
          total_seconds: result.total_seconds || 0,
          intersection_delays: result.intersection_count || 0,
          avg_seconds: safe_div(result.total_seconds, total)
        }
    end)
  end

  @doc """
  Returns all lines with recorded stats.
  """
  def lines_with_stats(opts \\ []) do
    since = Keyword.get(opts, :since, Date.add(Date.utc_today(), -30))

    from(s in __MODULE__,
      where: s.date >= ^since,
      distinct: s.line,
      select: s.line
    )
    |> Repo.all()
    |> Enum.sort_by(&safe_to_integer/1)
  end

  defp safe_to_integer(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end

  @doc """
  Upserts a daily stat record.
  """
  def upsert!(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [
           :delay_count,
           :blockage_count,
           :total_seconds,
           :intersection_count,
           :by_hour,
           :updated_at
         ]},
      conflict_target: [:date, :line]
    )
  end

  defp safe_div(_, 0), do: 0.0
  defp safe_div(nil, _), do: 0.0
  defp safe_div(num, denom), do: Float.round(num / denom, 1)
end
