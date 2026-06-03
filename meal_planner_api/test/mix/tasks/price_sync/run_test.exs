defmodule Mix.Tasks.PriceSync.RunTest do
  use ExUnit.Case, async: true

  describe "mix price_sync.run" do
    test "task module is defined" do
      assert is_atom(Mix.Tasks.PriceSync.Run)
    end

    test "has run/1 function (Mix.Task callback)" do
      assert is_function(&Mix.Tasks.PriceSync.Run.run/1, 1)
    end
  end
end
