defmodule WawTrams.Audit.CostCalculator do
  @moduledoc """
  Economic cost calculation for tram delays.

  Calculates the monetary impact of delays based on:
  - Passenger time lost (varies by time of day)
  - Operational costs (driver wages, energy)

  ## Configuration

  All values are configurable via application config:

      config :waw_trams, WawTrams.Audit.CostCalculator,
        vot_pln_per_hour: 22,
        driver_wage_pln_per_hour: 80,
        energy_pln_per_hour: 5,
        passengers_peak: 150,
        passengers_offpeak: 50,
        passengers_night: 10

  ## Example

      iex> CostCalculator.calculate(600, 8)  # 10 min delay at 8 AM
      %{total: 564, passenger: 550, operational: 14}
  """

  @default_config %{
    # Value of Time - Polish commuter weighted average
    vot_pln_per_hour: 22,
    # Driver full employer cost (incl. ZUS/taxes)
    driver_wage_pln_per_hour: 80,
    # Idling energy (~5 kW × ~1 PLN/kWh for HVAC, lights, computers)
    energy_pln_per_hour: 5,
    # Pesa Jazz packed capacity during rush hour
    passengers_peak: 150,
    # Moderate load mid-day and evening
    passengers_offpeak: 50,
    # Minimal night ridership
    passengers_night: 10
  }

  @doc """
  Returns the current configuration.
  """
  def config do
    Application.get_env(:waw_trams, __MODULE__, @default_config)
    |> Enum.into(@default_config)
  end

  @doc """
  Calculates the economic cost of a delay.

  ## Parameters
  - `delay_seconds` - Duration of the delay in seconds
  - `hour` - Hour of day (0-23) when delay occurred

  ## Returns

  Map with cost breakdown:
  - `:total` - Total cost in PLN
  - `:passenger` - Passenger time cost in PLN
  - `:operational` - Operational cost (driver + energy) in PLN
  - `:passengers` - Estimated passenger count used
  """
  def calculate(delay_seconds, hour) when is_integer(delay_seconds) and delay_seconds >= 0 do
    cfg = config()
    hours = delay_seconds / 3600
    passengers = passenger_estimate(hour, cfg)

    passenger_cost = hours * passengers * cfg.vot_pln_per_hour
    driver_cost = hours * cfg.driver_wage_pln_per_hour
    energy_cost = hours * cfg.energy_pln_per_hour
    operational_cost = driver_cost + energy_cost

    %{
      total: Float.round(passenger_cost + operational_cost, 2),
      passenger: Float.round(passenger_cost, 2),
      operational: Float.round(operational_cost, 2),
      passengers: passengers
    }
  end

  def calculate(nil, _hour), do: %{total: 0, passenger: 0, operational: 0, passengers: 0}

  @doc """
  Calculates total cost for a list of delays.

  ## Parameters
  - `delays` - List of maps with `:duration_seconds` and `:started_at` fields

  ## Returns

  Aggregated cost breakdown with additional `:count` field.
  """
  def calculate_total(delays) when is_list(delays) do
    result = Enum.reduce(delays, %{total: 0.0, passenger: 0.0, operational: 0.0, count: 0}, fn delay, acc ->
      hour = extract_hour(delay)
      cost = calculate(delay.duration_seconds || 0, hour)

      %{
        total: acc.total + cost.total,
        passenger: acc.passenger + cost.passenger,
        operational: acc.operational + cost.operational,
        count: acc.count + 1
      }
    end)

    %{
      total: Float.round(result.total, 2),
      passenger: Float.round(result.passenger, 2),
      operational: Float.round(result.operational, 2),
      count: result.count
    }
  end

  @doc """
  Returns estimated passenger count for a given hour.
  """
  def passenger_estimate(hour, cfg \\ config())

  # Morning peak: 7:00-8:59
  def passenger_estimate(hour, cfg) when hour in 7..8, do: cfg.passengers_peak

  # Afternoon peak: 15:00-17:59
  def passenger_estimate(hour, cfg) when hour in 15..17, do: cfg.passengers_peak

  # Daytime off-peak: 9:00-14:59
  def passenger_estimate(hour, cfg) when hour in 9..14, do: cfg.passengers_offpeak

  # Evening off-peak: 18:00-21:59
  def passenger_estimate(hour, cfg) when hour in 18..21, do: cfg.passengers_offpeak

  # Night: 22:00-6:59
  def passenger_estimate(_hour, cfg), do: cfg.passengers_night

  @doc """
  Formats cost for display with thousands separator.

  ## Examples

      iex> CostCalculator.format_pln(1234567)
      "1 234 567 PLN"

      iex> CostCalculator.format_pln(500.5)
      "501 PLN"
  """
  def format_pln(amount) when is_number(amount) do
    rounded = round(amount)

    formatted =
      rounded
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.join(" ")

    "#{formatted} PLN"
  end

  def format_pln(_), do: "0 PLN"

  # Extract hour from delay event
  defp extract_hour(%{started_at: %DateTime{} = dt}), do: dt.hour
  defp extract_hour(%{started_at: %NaiveDateTime{} = dt}), do: dt.hour
  defp extract_hour(_), do: 12
end
