defmodule WawTrams.LineTerminalTest do
  use WawTrams.DataCase, async: true

  alias WawTrams.{LineTerminal, Repo}

  # Helper to create a stop with PostGIS geometry
  defp create_stop(stop_id, name, lat, lon) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      """
      INSERT INTO stops (stop_id, name, geom, inserted_at, updated_at)
      VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), $5, $5)
      ON CONFLICT (stop_id) DO NOTHING
      """,
      [stop_id, name, lon, lat, now]
    )
  end

  describe "upsert!/1" do
    test "creates a new line terminal" do
      attrs = %{
        line: "15",
        stop_id: "100001",
        terminal_name: "Test Terminal",
        direction: "end"
      }

      terminal = LineTerminal.upsert!(attrs)

      assert terminal.line == "15"
      assert terminal.stop_id == "100001"
      assert terminal.terminal_name == "Test Terminal"
      assert terminal.direction == "end"
    end

    test "upsert does not fail on conflict" do
      attrs = %{
        line: "15",
        stop_id: "100001",
        terminal_name: "Original Name",
        direction: "start"
      }

      terminal1 = LineTerminal.upsert!(attrs)
      assert terminal1.id

      # Same line + stop_id = conflict, should not raise
      duplicate_attrs = %{
        line: "15",
        stop_id: "100001",
        terminal_name: "Duplicate",
        direction: "end"
      }

      # With on_conflict: :nothing, the second insert is ignored (no error)
      # and returns a struct without an id
      terminal2 = LineTerminal.upsert!(duplicate_attrs)
      assert is_nil(terminal2.id)

      # Only 1 record should exist
      assert LineTerminal.count() == 1
    end
  end

  describe "terminal_for_line?/3" do
    setup do
      # First create stops with geometry (required for spatial join)
      create_stop("100025", "Pl. Narutowicza", 52.2220, 20.9850)
      create_stop("100014", "Miasteczko Wilanow", 52.1650, 21.0800)

      # Then create line terminals referencing those stops
      LineTerminal.upsert!(%{
        line: "25",
        stop_id: "100025",
        terminal_name: "Pl. Narutowicza",
        direction: "end"
      })

      LineTerminal.upsert!(%{
        line: "14",
        stop_id: "100014",
        terminal_name: "Miasteczko Wilanow",
        direction: "end"
      })

      :ok
    end

    test "returns true when tram is at its line's terminal" do
      # Line 25 at Pl. Narutowicza (within 50m)
      assert LineTerminal.terminal_for_line?("25", 52.2220, 20.9850)
    end

    test "returns false when tram is at another line's terminal" do
      # Line 15 at Pl. Narutowicza - NOT a terminal for line 15
      refute LineTerminal.terminal_for_line?("15", 52.2220, 20.9850)
    end

    test "returns false when tram is not near any terminal" do
      # Random location in Warsaw (far from any stop)
      refute LineTerminal.terminal_for_line?("25", 52.3500, 21.1000)
    end

    test "returns false when line is nil" do
      refute LineTerminal.terminal_for_line?(nil, 52.2220, 20.9850)
    end
  end

  describe "terminals_for_line/1" do
    setup do
      LineTerminal.upsert!(%{
        line: "14",
        stop_id: "100001",
        terminal_name: "Terminal A",
        direction: "start"
      })

      LineTerminal.upsert!(%{
        line: "14",
        stop_id: "100002",
        terminal_name: "Terminal B",
        direction: "end"
      })

      LineTerminal.upsert!(%{
        line: "15",
        stop_id: "100003",
        terminal_name: "Terminal C",
        direction: "end"
      })

      :ok
    end

    test "returns all terminal stop_ids for a specific line" do
      stop_ids = LineTerminal.terminals_for_line("14")

      assert length(stop_ids) == 2
      assert "100001" in stop_ids
      assert "100002" in stop_ids
    end

    test "returns empty list for line with no terminals" do
      assert LineTerminal.terminals_for_line("99") == []
    end
  end

  describe "lines_with_terminal/1" do
    setup do
      # Narutowicza is terminal for lines 25 and 10
      LineTerminal.upsert!(%{
        line: "25",
        stop_id: "100025",
        terminal_name: "Pl. Narutowicza",
        direction: "end"
      })

      LineTerminal.upsert!(%{
        line: "10",
        stop_id: "100025",
        terminal_name: "Pl. Narutowicza",
        direction: "start"
      })

      :ok
    end

    test "returns all lines that have the given stop as terminal" do
      lines = LineTerminal.lines_with_terminal("100025")

      assert length(lines) == 2
      assert "25" in lines
      assert "10" in lines
    end

    test "returns empty list for unknown stop" do
      assert LineTerminal.lines_with_terminal("999999") == []
    end
  end

  describe "count/0" do
    test "returns total count of line terminals" do
      initial_count = LineTerminal.count()

      LineTerminal.upsert!(%{
        line: "1",
        stop_id: "100001",
        terminal_name: "Terminal 1",
        direction: "end"
      })

      LineTerminal.upsert!(%{
        line: "2",
        stop_id: "100002",
        terminal_name: "Terminal 2",
        direction: "start"
      })

      assert LineTerminal.count() == initial_count + 2
    end
  end
end
