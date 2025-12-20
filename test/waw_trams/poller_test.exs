defmodule WawTrams.PollerTest do
  use ExUnit.Case, async: true

  alias WawTrams.Poller

  describe "tram_line?/1" do
    test "returns true for tram lines 1-79" do
      assert Poller.tram_line?("1") == true
      assert Poller.tram_line?("17") == true
      assert Poller.tram_line?("33") == true
      assert Poller.tram_line?("79") == true
    end

    test "returns false for bus lines (100+)" do
      assert Poller.tram_line?("100") == false
      assert Poller.tram_line?("175") == false
      assert Poller.tram_line?("500") == false
    end

    test "returns false for line 0" do
      assert Poller.tram_line?("0") == false
    end

    test "returns false for lines > 79" do
      assert Poller.tram_line?("80") == false
      assert Poller.tram_line?("81") == false
    end

    test "returns false for night buses (N-prefix)" do
      assert Poller.tram_line?("N01") == false
      assert Poller.tram_line?("N45") == false
    end

    test "returns false for nil" do
      assert Poller.tram_line?(nil) == false
    end

    test "returns false for non-numeric strings" do
      assert Poller.tram_line?("abc") == false
      assert Poller.tram_line?("") == false
    end

    test "returns false for mixed alphanumeric" do
      assert Poller.tram_line?("17a") == false
      assert Poller.tram_line?("E-1") == false
    end

    # Edge cases for Warsaw tram network
    test "handles all actual Warsaw tram lines" do
      # Warsaw currently has tram lines: 1, 2, 3, 4, 6, 7, 9, 10, 11, 13, 14, 15, 16, 17, 18,
      # 19, 20, 22, 23, 24, 25, 26, 27, 28, 31, 33, 35
      actual_lines = ~w(1 2 3 4 6 7 9 10 11 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 31 33 35)

      for line <- actual_lines do
        assert Poller.tram_line?(line) == true, "Line #{line} should be a tram"
      end
    end
  end
end
