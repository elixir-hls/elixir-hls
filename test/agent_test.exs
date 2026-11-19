defmodule EHLS.AgentTest do
  use ExUnit.Case

  # EHLS.Agent: start_link, get_and_update, update, one state for the functions of several lines
  @moduletag :tmp_dir

  @src """
  defhls set_n(k :: u16, _n :: u16) :: {u16, u16} do
    {k, k}
  end

  defhls inc_n(_p :: u16, n :: u16) :: {u16, u16} do
    {n + 1, n + 1}
  end

  definstance panel(ks, ps) do
    {:ok, n} = EHLS.Agent.start_link(0)
    ks |> EHLS.Agent.update(n, &set_n/2)
    ps |> EHLS.Agent.get_and_update(n, &inc_n/2)
  end
  """

  defp compile(name, src, env) do
    old = for {k, _} <- env, into: %{}, do: {k, System.get_env(k)}
    for {k, v} <- env, do: System.put_env(k, v)

    try do
      Code.compile_string("defmodule #{name} do\nuse EHLS\n#{src}\nend")
    after
      for {k, v} <- old, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "on the CPU: one state, the lines in turn; without a name it is not read" do
    compile("AgentCpu", @src, %{"EHLS_PLACEMENT" => "cpu"})
    # set by the first line, counted on by the second
    assert AgentCpu.panel([5], [1, 1]) == [6, 7]
    assert AgentCpu.panel([], [1]) == [8]
    assert AgentCpu.panel([100], []) == []
    assert_raise ArgumentError, ~r/an agent is read when it has a name/, fn -> AgentCpu.panel(:get, :n) end

    # called as functions the same lines run on an Agent
    {:ok, a} = EHLS.Agent.start_link(0)
    :ok = [5] |> EHLS.Agent.update(a, &AgentCpu.set_n/2)
    assert [1, 1] |> EHLS.Agent.get_and_update(a, &AgentCpu.inc_n/2) |> Enum.to_list() == [6, 7]
    assert EHLS.Agent.get(a) == 7
  end

  test "an agent with a name: EHLS.Agent.get(Name, fun) reads it from the CPU, as Agent.get" do
    src = String.replace(@src, "{:ok, n} = EHLS.Agent.start_link(0)", "{:ok, n} = EHLS.Agent.start_link(0, name: AgentNamed.Count)")
    compile("AgentNamed", src, %{"EHLS_PLACEMENT" => "cpu"})
    assert AgentNamed.panel([5], [1, 1]) == [6, 7]
    assert EHLS.Agent.get(AgentNamed.Count, & &1) == 7
    assert EHLS.Agent.get(AgentNamed.Count, &(&1 * 2)) == 14

    # a name is a module's: one there already stops the compile
    assert_raise CompileError, ~r/a module of that name is there already/, fn ->
      compile("AgentNamed2", String.replace(src, "AgentNamed.Count", "Enum"), %{"EHLS_PLACEMENT" => "cpu"})
    end
  end

  test "in the FPGA: the functions of an agent marked so; with a name the first is read from the CPU", %{tmp_dir: dir} do
    compile("AgentFpga", @src, %{"EHLS_PLACEMENT" => "fpga", "EHLS_SOC" => "litex", "EHLS_OUT_DIR" => dir})
    p = dir |> Path.join("agent_fpga_panel.pipeline") |> File.read!() |> JSON.decode!()
    kernels = for st <- p["stages"], st["kernel"], do: {st["kernel"], st["agent"], st["state_name"]}
    # no name: no circuit to read it
    assert {"agent_fpga_set_n__s", "n", nil} in kernels
    assert {"agent_fpga_inc_n__s", "n", nil} in kernels

    named = String.replace(@src, "{:ok, n} = EHLS.Agent.start_link(0)", "{:ok, n} = EHLS.Agent.start_link(0, name: AgentFpgaN.Count)")
    compile("AgentFpgaN", named, %{"EHLS_PLACEMENT" => "fpga", "EHLS_SOC" => "litex", "EHLS_OUT_DIR" => dir})
    p = dir |> Path.join("agent_fpga_n_panel.pipeline") |> File.read!() |> JSON.decode!()
    kernels = for st <- p["stages"], st["kernel"], do: {st["kernel"], st["agent"], st["state_name"]}
    assert {"agent_fpga_n_set_n__s", "n", "n"} in kernels
    assert {"agent_fpga_n_inc_n__s", "n", nil} in kernels
  end

  test "what cannot be an agent stops the compile" do
    msg = fn body ->
      assert_raise(CompileError, fn ->
        compile("AgentBad#{System.unique_integer([:positive])}", """
        defhls count(_x :: u16, n :: u16) :: {u16, u16} do
          {n + 1, n + 1}
        end
        defhls wide(_x :: u16, n :: u32) :: {u32, u32} do
          {n + 1, n + 1}
        end
        defhls plain(x :: u16) :: u16 do
          x
        end
        #{body}
        """, %{"EHLS_PLACEMENT" => "cpu"})
      end).description
    end

    start = "{:ok, n} = EHLS.Agent.start_link(0)\n"
    assert msg.("definstance a(x) do\nx |> EHLS.Agent.get_and_update(m, &count/2)\nend") =~ "need an agent"
    assert msg.("definstance a(x, y) do\n#{start}x |> EHLS.Agent.update(n, &count/2)\ny |> EHLS.Agent.get_and_update(n, &wide/2)\nend") =~ "states are"
    assert msg.("definstance a(x) do\n#{start}x |> EHLS.Agent.get_and_update(n, &plain/2)\nend") =~ "plain takes no state"
    assert msg.("definstance a(x) do\n#{start}{:ok, m} = EHLS.Agent.start_link(1)\nx |> EHLS.Agent.get_and_update(n, &count/2)\nend") =~ "the agent m is used by no"
    # written with the module, as Elixir's Agent; start_link gives {:ok, agent}
    assert msg.("definstance a(x) do\nn = agent(0)\nx |> get_and_update(n, &count/2)\nend") =~ "EHLS.Agent.start_link(...)"
    assert msg.("definstance a(x) do\nn = EHLS.Agent.start_link(0)\nx |> EHLS.Agent.get_and_update(n, &count/2)\nend") =~ "{:ok, n} = EHLS.Agent.start_link"
    assert msg.("definstance a(x) do\n#{start}x |> EHLS.Agent.update(n, &count/2) |> EHLS.Agent.get(n)\nend") =~ "not there yet"
  end
end
