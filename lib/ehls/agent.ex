defmodule EHLS.Agent do
  @moduledoc """
  One state for several lines of an instance, as Elixir's `Agent`: the functions an instance writes with this module.

  ```elixir
  defhls set_n(k :: u16, _n :: u16) :: {u16, u16} do
    {k, k}
  end

  defhls inc_n(_tick :: u32, n :: u16) :: {u16, u16} do
    {n + 1, n + 1}
  end

  definstance panel do
    {:ok, n} = EHLS.Agent.start_link(0, name: MyApp.Count)
    changes(k_hw(:value)) |> EHLS.Agent.update(n, &set_n/2)
    ticks(200) |> EHLS.Agent.get_and_update(n, &inc_n/2) |> EHLS.PubSub.broadcast(:count)
  end

  EHLS.Agent.get(MyApp.Count, & &1)    # the state, from the CPU (an agent with a name)
  ```

  Placed, the agent is a register in the circuit, and its functions take it in turn, one element at a time, in the
  order the elements come (in turn among those that come at once); each sees the state the one before left. Called as
  functions, on the CPU, they are `Agent`'s, on a real agent: so the same lines can be tried in `iex` or `mix test`.

  Two things differ from `Agent`, both because the functions are in a pipe:

  - the function given to `get_and_update/3` and `update/3` takes the element as well as the state, `f(x, state)`, and
    returns `{output, next_state}` (`EHLS.Stream.transform/4`'s function);
  - `start_link/1` takes the initial value itself, written with literals, not a function giving it.

  The CPU reads the state while the instance runs when the agent has a name, `start_link(initial, name: MyApp.Count)`:
  `EHLS.Agent.get(MyApp.Count, fun)`. Without a name the circuit to read it is not made.
  """

  @doc """
  An agent starting at `initial`, as `Agent.start_link/2`: `{:ok, agent}`.

  In a `definstance`, `{:ok, n} = EHLS.Agent.start_link(initial)` names the agent `n` in the instance; with
  `name: MyApp.Count` (a module name, as an `Agent`'s name usually is) the CPU reads it with
  `EHLS.Agent.get(MyApp.Count, fun)`.
  """
  def start_link(initial, opts \\ []), do: Agent.start_link(fn -> initial end, opts)

  @doc """
  Each element through `f(x, state)`, as `Agent.get_and_update/3` does for one call: the state becomes the next state, and
  the output goes on in the pipe. The output is the element itself, `{y, s}`, or a list of at most one, `{[y], s}` /
  `{[], s}`.
  """
  def get_and_update(enum, agent, f) when is_function(f, 2) do
    Stream.flat_map(enum, fn x ->
      Agent.get_and_update(agent, fn s ->
        case f.(x, s) do
          {ys, s} when is_list(ys) -> {ys, s}
          {y, s} -> {[y], s}
        end
      end)
    end)
  end

  @doc """
  Each element through `f(x, state)`, as `Agent.update/3`: only the next state is kept. It ends a pipe; returns `:ok`.
  """
  def update(enum, agent, f) when is_function(f, 2) do
    Enum.each(enum, fn x -> Agent.update(agent, fn s -> elem(f.(x, s), 1) end) end)
  end

  @doc """
  The agent's state through `fun`, as `Agent.get/2`: an agent of an instance by the name it was given,
  `EHLS.Agent.start_link(initial, name: MyApp.Count)` (read from the instance, in the FPGA or on the CPU), or one
  `start_link/1` started as a function.
  """
  def get(agent, fun \\ & &1)

  def get(agent, fun) when is_pid(agent), do: Agent.get(agent, fun)

  def get(name, fun) when is_atom(name) do
    {module, instance, n} = name.__ehls_agent__()
    fun.(apply(module, instance, [:get, n]))
  end
end
