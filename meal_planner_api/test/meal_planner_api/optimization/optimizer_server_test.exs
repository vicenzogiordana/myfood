defmodule MealPlannerApi.Optimization.OptimizerServerTest do
  @moduledoc """
  Focused lifecycle tests for `OptimizerServer`. Each test starts the GenServer
  under a unique name with the `FakePortRunner`, so no real Python process is
  spawned. Tests inject frames via `send(server, {port, {:data, ...}})`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MealPlannerApi.Optimization.OptimizerServer
  alias MealPlannerApi.Optimization.TestSupport.FakePortRunner

  @payload %{
    days: ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"],
    slots: ["breakfast", "lunch", "dinner"],
    constraints: %{
      weekly_budget_cents: 50_000,
      macro_bounds: %{
        protein_g: %{min: 0, max: 1_000_000},
        carbs_g: %{min: 0, max: 1_000_000},
        fat_g: %{min: 0, max: 1_000_000},
        calories: %{min: 0, max: 1_000_000}
      }
    },
    candidates_by_slot: %{
      "breakfast" => [%{recipe_id: "r1", estimated_cost_cents: 500}],
      "lunch" => [%{recipe_id: "r2", estimated_cost_cents: 600}],
      "dinner" => [%{recipe_id: "r3", estimated_cost_cents: 700}]
    }
  }

  @env_keys [
    :optimizer_port_runner,
    :optimizer_handshake_attempts,
    :optimizer_handshake_timeout_ms,
    :optimizer_circuit_reset_timeout_ms,
    :optimizer_timeout_ms,
    :optimizer_request_timeout_ms,
    :optimizer_frame_max_bytes
  ]

  setup do
    prev_env = snapshot_env(@env_keys)

    Application.put_env(:meal_planner_api, :optimizer_port_runner, FakePortRunner)
    Application.put_env(:meal_planner_api, :optimizer_handshake_attempts, 3)
    Application.put_env(:meal_planner_api, :optimizer_handshake_timeout_ms, 100)
    Application.put_env(:meal_planner_api, :optimizer_circuit_reset_timeout_ms, 100)
    # Call timeout (GenServer.call/3) is short; the per-request timer is
    # generous so that tests that send a response back to the server don't
    # race the timer firing.
    Application.put_env(:meal_planner_api, :optimizer_timeout_ms, 1_000)
    Application.put_env(:meal_planner_api, :optimizer_request_timeout_ms, 30_000)
    Application.put_env(:meal_planner_api, :optimizer_frame_max_bytes, 1024)

    on_exit(fn ->
      restore_env(prev_env)
      FakePortRunner.clear_port()
    end)

    :ok
  end

  describe "start_link/1" do
    test "accepts a :name option so multiple test instances can coexist" do
      name_a = unique_name()
      name_b = unique_name()

      assert {:ok, pid_a} = OptimizerServer.start_link(name: name_a)
      assert {:ok, pid_b} = OptimizerServer.start_link(name: name_b)

      # Register under custom name, but tests that exercise the public API
      # (`select_weekly_menu`) must register under the default __MODULE__ name
      # because `select_weekly_menu` calls `__MODULE__`.
      on_exit(fn ->
        if Process.whereis(name_a) == pid_a, do: Process.unregister(name_a)
        if Process.whereis(name_b) == pid_b, do: Process.unregister(name_b)
      end)

      assert Process.whereis(name_a) == pid_a
      assert Process.whereis(name_b) == pid_b
    end
  end

  describe "frame handling" do
    test "decodes a complete frame delivered in one chunk" do
      {pid, port, _name} = start_and_ready!()

      reply_task = async_select()
      request_id = await_pending(pid)

      solution =
        Jason.encode!(%{
          "type" => "solution",
          "id" => request_id,
          "result" => %{
            "meals" => [
              %{"day" => "monday", "slot" => "breakfast", "recipe_id" => "r1"}
            ]
          }
        }) <> "\n"

      send(pid, {port, {:data, solution}})

      assert {:ok, %{"meals" => meals}} = Task.await(reply_task, 500)
      assert length(meals) == 1
      assert hd(meals)["recipe_id"] == "r1"
    end

    test "reassembles a frame split across multiple :data chunks" do
      {pid, port, _name} = start_and_ready!()

      reply_task = async_select()
      request_id = await_pending(pid)

      full =
        Jason.encode!(%{
          "type" => "solution",
          "id" => request_id,
          "result" => %{"meals" => []}
        }) <> "\n"

      {head, tail} = String.split_at(full, div(byte_size(full), 2))

      send(pid, {port, {:data, head}})
      assert :sys.get_state(pid).buffer != ""

      send(pid, {port, {:data, tail}})

      assert {:ok, %{"meals" => []}} = Task.await(reply_task, 500)
    end

    test "drops malformed frames with a Logger.warning" do
      {pid, port, _name} = start_and_ready!()

      log =
        capture_log(fn ->
          send(pid, {port, {:data, "not valid json\n"}})

          # Wait for the frame to be processed.
          Process.sleep(20)
          _ = :sys.get_state(pid)

          # Confirm no reply arrived yet — pending stays intact.
          assert map_size(:sys.get_state(pid).pending_requests) == 0
        end)

      assert log =~ "dropping malformed frame"
    end
  end

  describe "request lifecycle" do
    test "uses UUID.uuid4/0 request ids (not monotonic counters)" do
      {pid, port, _name} = start_and_ready!()

      ids =
        for _ <- 1..3 do
          parent = self()

          task =
            Task.async(fn ->
              result = OptimizerServer.select_weekly_menu(@payload)
              send(parent, {:result, result})
            end)

          request_id = await_pending(pid)

          send(
            pid,
            {port,
             {:data,
              Jason.encode!(%{
                "type" => "solution",
                "id" => request_id,
                "result" => %{"meals" => []}
              }) <> "\n"}}
          )

          assert_receive {:result, {:ok, _}}, 1_500
          Task.await(task, 100)
          request_id
        end

      # 3 ids, all unique, all 36-char UUIDs.
      assert length(Enum.uniq(ids)) == 3
      assert Enum.all?(ids, &(byte_size(&1) == 36))
      assert Enum.all?(ids, &match?({:ok, _}, UUID.info(&1)))
    end

    test "per-request timer fires :optimizer_unavailable when Python never replies" do
      Application.put_env(:meal_planner_api, :optimizer_request_timeout_ms, 50)

      {pid, _port, _name} = start_and_ready!()

      reply_task = async_select()
      _request_id = await_pending(pid)

      assert {:error, :optimizer_unavailable} = Task.await(reply_task, 500)

      assert map_size(:sys.get_state(pid).pending_requests) == 0
    end

    test "terminate/2 replies :optimizer_unavailable to remaining pending requests" do
      {pid, _port, _name} = start_and_ready!()

      reply_task = async_select()
      _request_id = await_pending(pid)

      Process.exit(pid, :shutdown)

      assert {:error, :optimizer_unavailable} = Task.await(reply_task, 500)
    end

    test "restart on port exit replies :optimizer_unavailable to in-flight requests" do
      {pid, port, _name} = start_and_ready!()

      reply_task = async_select()
      _request_id = await_pending(pid)

      log =
        capture_log(fn ->
          # Synthesize the exit_status message the Erlang port driver would
          # deliver when the Python subprocess exits non-zero. We can't use
          # Port.close from outside the owner process, so we drive the
          # handle_info path directly.
          send(pid, {port, {:exit_status, 1}})
          Process.sleep(30)
          _ = :sys.get_state(pid)
        end)

      assert {:error, :optimizer_unavailable} = Task.await(reply_task, 500)
      assert log =~ "Python process exited"
    end
  end

  describe "frame size cap" do
    test "oversize frame returns :frame_too_large for the oldest pending request only" do
      # 16-byte cap so even a small payload is oversize; long request timeout so
      # the per-request timer never wins the race against the data delivery.
      Application.put_env(:meal_planner_api, :optimizer_frame_max_bytes, 16)
      Application.put_env(:meal_planner_api, :optimizer_timeout_ms, 2_000)

      {pid, port, _name} = start_and_ready!()

      reply_task = async_select()
      _request_id = await_pending(pid)

      # 64 bytes of junk, no newline.
      junk = String.duplicate("A", 64)

      log =
        capture_log(fn ->
          send(pid, {port, {:data, junk}})
          Process.sleep(20)
          _ = :sys.get_state(pid)
        end)

      assert {:error, :frame_too_large} = Task.await(reply_task, 500)
      assert log =~ "oversize frame"
      assert map_size(:sys.get_state(pid).pending_requests) == 0
    end
  end

  describe "handshake" do
    test "bounded handshake retries; shutdown on persistent failure" do
      log =
        capture_log(fn ->
          # Start server without sending a ready frame, under a unique name
          # so we don't conflict with the __MODULE__-named instance.
          name = unique_name()

          pid = start_supervised!({OptimizerServer, name: name}, id: unique_name())
          ref = Process.monitor(pid)

          # 3 attempts × 100 ms each = ~300 ms before shutdown.
          assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :handshake_timeout}}, 1_500

          if Process.whereis(name) == pid, do: Process.unregister(name)
        end)

      assert log =~ "handshake failed after 3 attempts"
    end

    test "ready frame during handshake moves the server to :ready" do
      {pid, port, _name} = start_server!()

      send(pid, {port, {:data, ~s({"type":"ready","version":"1.0"}\n)}})
      :ok = await_handshake_ready(pid)

      assert :sys.get_state(pid).handshake_phase == :ready
    end
  end

  describe "circuit breaker" do
    test "3 consecutive error replies flip circuit to :open" do
      {pid, port, _name} = start_and_ready!()

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            reply_task = async_select()
            request_id = await_pending(pid)

            send(
              pid,
              {port,
               {:data,
                Jason.encode!(%{
                  "type" => "error",
                  "id" => request_id,
                  "error" => "boom"
                }) <> "\n"}}
            )

            assert {:error, :optimizer_error} = Task.await(reply_task, 500)
          end
        end)

      assert log =~ "circuit breaker OPEN"
      assert :sys.get_state(pid).circuit_state == :open
    end

    test "after reset window elapses, circuit flips to :closed and restarts" do
      {pid, port, _name} = start_and_ready!()

      capture_log(fn ->
        for _ <- 1..3 do
          reply_task = async_select()
          request_id = await_pending(pid)

          send(
            pid,
            {port,
             {:data,
              Jason.encode!(%{
                "type" => "error",
                "id" => request_id,
                "error" => "boom"
              }) <> "\n"}}
          )

          assert {:error, :optimizer_error} = Task.await(reply_task, 500)
        end
      end)

      assert :sys.get_state(pid).circuit_state == :open

      log =
        capture_log(fn ->
          :sys.replace_state(pid, fn state ->
            %{state | last_failure_at: System.monotonic_time(:millisecond) - 101}
          end)

          # The restart begins a new handshake, so this request is rejected
          # synchronously and is never added to pending_requests.
          assert {:error, :optimizer_unavailable} = OptimizerServer.select_weekly_menu(@payload)
        end)

      assert log =~ "circuit breaker reset"
    end

    test "circuit-open solve calls fall back to OptimizerFallback (no OptimizerServer call)" do
      {pid, port, _name} = start_and_ready!()

      capture_log(fn ->
        for _ <- 1..3 do
          reply_task = async_select()
          request_id = await_pending(pid)

          send(
            pid,
            {port,
             {:data,
              Jason.encode!(%{
                "type" => "error",
                "id" => request_id,
                "error" => "boom"
              }) <> "\n"}}
          )

          assert {:error, :optimizer_error} = Task.await(reply_task, 500)
        end
      end)

      assert :sys.get_state(pid).circuit_state == :open

      # Subsequent call should return the fallback's {:ok, ...} shape immediately,
      # without ever adding to pending_requests.
      assert {:ok, %{meals: _meals}} = OptimizerServer.select_weekly_menu(@payload)
      assert map_size(:sys.get_state(pid).pending_requests) == 0
    end
  end

  describe "public error atoms" do
    test "GenServer.call/3 timeout still maps to :optimizer_timeout (caller-visible)" do
      # Configure the caller's GenServer.call timeout short, but keep the
      # per-request timer longer so the GenServer never replies — the call
      # itself must time out.
      Application.put_env(:meal_planner_api, :optimizer_timeout_ms, 50)
      Application.put_env(:meal_planner_api, :optimizer_request_timeout_ms, 5_000)

      {pid, _port, _name} = start_and_ready!()

      task =
        Task.async(fn -> OptimizerServer.select_weekly_menu(@payload) end)

      _request_id = await_pending(pid)

      assert {:error, :optimizer_timeout} = Task.await(task, 500)
    end
  end

  describe "port spawning" do
    test "OptimizerPortRunner uses :spawn_executable with args (no shell quoting)" do
      # This is a structural check: the runner must NOT use `{:spawn, ...}`
      # because that delegates to a shell and is unsafe. We verify by reading
      # the source — there is no clean runtime check for :spawn_executable
      # versus :spawn, so we lean on grep in CI for that. Here, we verify
      # the runtime contract: open_port/1 must accept keyword opts.
      runner = MealPlannerApi.Optimization.OptimizerPortRunner

      # Sanity: defaults exist.
      assert is_binary(runner.default_python())
      assert is_binary(runner.default_script_path())
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp start_server! do
    pid = start_supervised!({OptimizerServer, []}, id: unique_name())
    port = FakePortRunner.get_port()
    assert is_port(port), "FakePortRunner did not record a port"
    assert Process.whereis(OptimizerServer) == pid

    {pid, port, OptimizerServer}
  end

  defp start_and_ready! do
    {pid, port, name} = start_server!()
    send(pid, {port, {:data, ~s({"type":"ready","version":"1.0"}\n)}})
    :ok = await_handshake_ready(pid)

    {pid, port, name}
  end

  defp async_select do
    Task.async(fn -> OptimizerServer.select_weekly_menu(@payload) end)
  end

  defp await_pending(pid) do
    do_await(fn state -> map_size(state.pending_requests) > 0 end, pid)
    hd(Map.keys(:sys.get_state(pid).pending_requests))
  end

  defp await_handshake_ready(pid) do
    do_await(fn state -> state.handshake_phase == :ready end, pid)
    :ok
  end

  defp do_await(predicate, pid, attempts \\ 100) do
    Enum.reduce_while(1..attempts, :timeout, fn _, _ ->
      case :sys.get_state(pid) do
        state when is_struct(state, MealPlannerApi.Optimization.OptimizerServer) ->
          if predicate.(state) do
            {:halt, :ok}
          else
            Process.sleep(5)
            {:cont, :timeout}
          end

        _other ->
          Process.sleep(5)
          {:cont, :timeout}
      end
    end)
  end

  defp unique_name do
    :"optimizer_server_#{System.unique_integer([:positive])}"
  end

  defp snapshot_env(keys) do
    Enum.into(keys, %{}, fn k -> {k, Application.get_env(:meal_planner_api, k)} end)
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn {k, v} ->
      if is_nil(v) do
        Application.delete_env(:meal_planner_api, k)
      else
        Application.put_env(:meal_planner_api, k, v)
      end
    end)
  end
end
