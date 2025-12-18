defmodule WawTrams.TramSupervisor do
  @moduledoc """
  DynamicSupervisor for managing TramWorker processes.

  Each active tram in the network gets its own worker process,
  allowing ~450 concurrent processes to track vehicle state independently.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a TramWorker for the given vehicle ID, or returns existing one.
  """
  def start_worker(vehicle_id) do
    case whereis_worker(vehicle_id) do
      nil ->
        child_spec = {WawTrams.TramWorker, vehicle_id: vehicle_id}
        DynamicSupervisor.start_child(__MODULE__, child_spec)

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Finds the PID of a worker by vehicle ID.
  """
  def whereis_worker(vehicle_id) do
    case Registry.lookup(WawTrams.TramRegistry, vehicle_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Returns count of active workers.
  """
  def worker_count do
    DynamicSupervisor.count_children(__MODULE__)[:workers]
  end

  @doc """
  Returns list of all active vehicle IDs.
  """
  def active_vehicles do
    Registry.select(WawTrams.TramRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
