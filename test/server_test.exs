defmodule EHLS.ServerTest do
  use ExUnit.Case

  # EHLS.Server owning instances placed on the CPU (no board here): the same calls as on a board
  setup_all do
    old = System.get_env("EHLS_PLACEMENT")
    System.put_env("EHLS_PLACEMENT", "cpu")

    try do
      Code.compile_string("""
      defmodule ServerCase do
        use EHLS

        defhls running(x :: u16, acc :: u32) :: {u32, u32} do
          {acc + x, acc + x}
        end

        definstance summing(x) do
          x |> transform(0, &running/2, name: :sum)
        end

        definstance gain(k :: u8), initial: 3 do
          k
        end
      end

      defmodule ServerCut do
        use EHLS
        defhls inc(x :: u16) :: u16 do
          x + 1
        end
        definstance cut(w), on: :fpga do
          w |> map(&inc/1) |> map(&inc/1, on: :cpu) |> map(&inc/1)
        end
      end
      """)
    after
      System.put_env("EHLS_PLACEMENT", old || "fpga")
    end

    :ok
  end

  test "calls in the server, from the initial state; a cast; the value of an instance of levels" do
    ServerCase.summing([5])
    {:ok, s} = EHLS.Server.start_link(instance: {ServerCase, :summing})
    # init/1 stopped and started it: from 0, not from 5
    assert EHLS.Server.call(s, [[1, 2]]) == [1, 3]
    assert EHLS.Server.call(s, [:state, :sum]) == 3
    :ok = EHLS.Server.cast(s, [[4]])
    assert EHLS.Server.call(s, [:state, :sum]) == 7

    {:ok, g} = EHLS.Server.start_link(instance: {ServerCase, :gain}, name: Gain)
    assert EHLS.Server.value(Gain) == 3
    assert EHLS.Server.call(Gain, [10]) == 10
    assert EHLS.Server.value(g) == 10
    assert %{calls: 3, casts: 1, errors: 0, timeouts: 0} = EHLS.Server.stats(s)
  end

  test "a call that raises answers an error and the server goes on" do
    {:ok, s} = EHLS.Server.start_link(instance: {ServerCase, :summing})
    assert {:error, {:error, _}} = EHLS.Server.call(s, [[:not_a_number]])
    assert EHLS.Server.call(s, [[1]]) == [1]
    assert %{errors: 1} = EHLS.Server.stats(s)
  end

  test "callers wait their turn: many at once, each its own result" do
    {:ok, s} = EHLS.Server.start_link(instance: {ServerCase, :summing})
    me = self()
    for i <- 1..20, do: spawn(fn -> send(me, {:got, EHLS.Server.call(s, [[i]])}) end)
    got = for _ <- 1..20, do: receive(do: ({:got, [v]} -> v))
    # the running sum went through every call once
    assert Enum.max(got) == Enum.sum(1..20)
  end

  test "events handed on to the processes that asked, of the server's topics only" do
    {:ok, s} = EHLS.Server.start_link(instance: {ServerCase, :gain}, topics: [])
    assert EHLS.Server.subscribe(s, :presses) == {:error, {:not_a_topic_of_the_server, :presses}}
  end

  test "an instance cut by a function on the CPU: no stop / start of its own, the drivers started with cpu:" do
    # the driver is the target's: a stand-in giving back what it is started with
    Code.compile_string("defmodule EHLS.CpuDriver do\n def start(spec), do: spec\nend")
    {:ok, s} = EHLS.Server.start_link(instance: {ServerCut, :cut}, cpu: [batch: 3])
    assert %{opts: [batch: 3]} = :sys.get_state(s).cpu
  after
    :code.purge(EHLS.CpuDriver)
    :code.delete(EHLS.CpuDriver)
  end

  test "a supervisor starts it from its child spec" do
    {:ok, sup} = Supervisor.start_link([{EHLS.Server, instance: {ServerCase, :gain}, name: SupGain}], strategy: :one_for_one)
    assert EHLS.Server.value(SupGain) == 3
    Supervisor.stop(sup)
  end
end
