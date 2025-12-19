defmodule WawTrams.Audit.CostCalculatorTest do
  use ExUnit.Case, async: true

  alias WawTrams.Audit.CostCalculator

  describe "calculate/2" do
    test "calculates cost for morning peak (150 passengers)" do
      # 10 minute delay at 8 AM
      result = CostCalculator.calculate(600, 8)

      assert result.passengers == 150
      # 0.167h × 150 × 22 = ~550
      assert result.passenger >= 545 and result.passenger <= 555
      # 0.167h × 85 = ~14
      assert result.operational >= 13 and result.operational <= 15
      assert result.total == result.passenger + result.operational
    end

    test "calculates cost for night (10 passengers)" do
      # 10 minute delay at 2 AM
      result = CostCalculator.calculate(600, 2)

      assert result.passengers == 10
      # 0.167h × 10 × 22 = ~37
      assert result.passenger >= 36 and result.passenger <= 38
      # Operational stays the same
      assert result.operational >= 13 and result.operational <= 15
    end

    test "handles zero delay" do
      result = CostCalculator.calculate(0, 8)

      assert result.total == 0
      assert result.passenger == 0
      assert result.operational == 0
    end

    test "handles nil delay" do
      result = CostCalculator.calculate(nil, 8)

      assert result.total == 0
    end

    test "uses offpeak passengers during mid-day" do
      result = CostCalculator.calculate(600, 11)
      assert result.passengers == 50
    end

    test "uses offpeak passengers during evening" do
      result = CostCalculator.calculate(600, 19)
      assert result.passengers == 50
    end

    test "uses peak passengers during afternoon rush" do
      result = CostCalculator.calculate(600, 16)
      assert result.passengers == 150
    end
  end

  describe "calculate_total/1" do
    test "sums costs for multiple delays" do
      delays = [
        %{duration_seconds: 600, started_at: ~U[2025-01-01 08:00:00Z]},
        %{duration_seconds: 600, started_at: ~U[2025-01-01 08:00:00Z]}
      ]

      result = CostCalculator.calculate_total(delays)

      # Should be ~2x single delay cost
      single = CostCalculator.calculate(600, 8)
      assert_in_delta result.total, single.total * 2, 1
      assert result.count == 2
    end

    test "handles empty list" do
      result = CostCalculator.calculate_total([])

      assert result.total == 0
      assert result.count == 0
    end

    test "extracts hour from DateTime" do
      delays = [
        %{duration_seconds: 600, started_at: ~U[2025-01-01 08:30:00Z]}
      ]

      result = CostCalculator.calculate_total(delays)

      # Should use hour 8 (peak)
      assert result.total > 500
    end
  end

  describe "passenger_estimate/2" do
    test "returns peak for 7-8 AM" do
      assert CostCalculator.passenger_estimate(7) == 150
      assert CostCalculator.passenger_estimate(8) == 150
    end

    test "returns peak for 3-5 PM" do
      assert CostCalculator.passenger_estimate(15) == 150
      assert CostCalculator.passenger_estimate(16) == 150
      assert CostCalculator.passenger_estimate(17) == 150
    end

    test "returns offpeak for mid-day" do
      for hour <- 9..14 do
        assert CostCalculator.passenger_estimate(hour) == 50
      end
    end

    test "returns offpeak for evening" do
      for hour <- 18..21 do
        assert CostCalculator.passenger_estimate(hour) == 50
      end
    end

    test "returns night for late/early hours" do
      for hour <- [22, 23, 0, 1, 2, 3, 4, 5, 6] do
        assert CostCalculator.passenger_estimate(hour) == 10
      end
    end
  end

  describe "format_pln/1" do
    test "formats with thousands separator" do
      assert CostCalculator.format_pln(1234567) == "1 234 567 PLN"
    end

    test "handles small numbers" do
      assert CostCalculator.format_pln(500) == "500 PLN"
    end

    test "rounds floats" do
      assert CostCalculator.format_pln(500.7) == "501 PLN"
    end

    test "handles nil" do
      assert CostCalculator.format_pln(nil) == "0 PLN"
    end
  end
end
