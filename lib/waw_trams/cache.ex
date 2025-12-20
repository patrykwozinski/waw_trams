defmodule WawTrams.Cache do
  @moduledoc """
  Simple ETS-based cache for expensive queries.

  Caches expensive aggregation queries with a TTL to reduce database load.
  Uses built-in ETS — no external dependencies required.

  ## Cache Keys

  Audit page:
  - `{:audit_stats, since, line}` — Summary statistics
  - `{:audit_leaderboard, since, line, limit}` — Top intersections

  Dashboard page:
  - `{:dashboard_impacted_lines, limit}` — Most impacted lines

  ## TTL Strategy

  - Audit stats: 30s
  - Audit leaderboard: 60s
  - Dashboard queries: 30s (matches refresh interval)

  Real-time delay events update the UI instantly via PubSub,
  so slightly stale aggregate numbers are acceptable.
  """

  use GenServer
  require Logger

  @table_name :waw_trams_cache
  @audit_stats_ttl_ms 30_000
  @audit_leaderboard_ttl_ms 60_000
  @dashboard_ttl_ms 30_000
  @cleanup_interval_ms 60_000

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Audit Page ---

  @doc """
  Get cached audit stats or compute and cache them.
  """
  def get_audit_stats(opts \\ []) do
    key = {:audit_stats, opts[:since], opts[:line]}

    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = WawTrams.Audit.Summary.stats_uncached(opts)
        put(key, value, @audit_stats_ttl_ms)
        value
    end
  end

  @doc """
  Get cached audit leaderboard or compute and cache it.
  """
  def get_audit_leaderboard(opts \\ []) do
    key = {:audit_leaderboard, opts[:since], opts[:line], opts[:limit]}

    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = WawTrams.Audit.Summary.leaderboard_uncached(opts)
        put(key, value, @audit_leaderboard_ttl_ms)
        value
    end
  end

  # --- Dashboard Page ---

  @doc """
  Get cached dashboard impacted lines.
  """
  def get_dashboard_impacted_lines(opts \\ []) do
    key = {:dashboard_impacted_lines, opts[:limit]}

    fetch_cached(key, @dashboard_ttl_ms, fn ->
      WawTrams.Queries.HotSpots.impacted_lines(opts)
    end)
  end

  # --- General ---

  @doc """
  Generic fetch with caching. Computes value if not cached.
  """
  def fetch_cached(key, ttl_ms, compute_fn) do
    case get(key) do
      {:ok, value} ->
        value

      :miss ->
        value = compute_fn.()
        put(key, value, ttl_ms)
        value
    end
  end

  @doc """
  Invalidate all cached data. Called when aggregation runs.
  """
  def invalidate_all do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, :invalidate_all)
    end
  end

  @doc """
  Get cache statistics for monitoring.
  """
  def cache_stats do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :stats)
    else
      %{size: 0, hits: 0, misses: 0}
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()

    Logger.info("[Cache] Query cache started")

    {:ok, %{table: table, hits: 0, misses: 0}}
  end

  @impl true
  def handle_cast(:invalidate_all, state) do
    :ets.delete_all_objects(@table_name)
    Logger.debug("[Cache] Invalidated all entries")
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    size = :ets.info(@table_name, :size)
    {:reply, %{size: size, hits: state.hits, misses: state.misses}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    expired = :ets.select(@table_name, [{{:"$1", :_, :"$2"}, [{:<, :"$2", now}], [:"$1"]}])

    if expired != [] do
      Enum.each(expired, &:ets.delete(@table_name, &1))
      Logger.debug("[Cache] Cleaned up #{length(expired)} expired entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # --- Private ---

  defp get(key) do
    # Handle race condition: table might not exist during startup
    if :ets.whereis(@table_name) == :undefined do
      :miss
    else
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table_name, key) do
        [{^key, value, expires_at}] when expires_at > now ->
          {:ok, value}

        _ ->
          :miss
      end
    end
  end

  defp put(key, value, ttl_ms) do
    # Handle race condition: table might not exist during startup
    if :ets.whereis(@table_name) != :undefined do
      expires_at = System.monotonic_time(:millisecond) + ttl_ms
      :ets.insert(@table_name, {key, value, expires_at})
    end

    :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
