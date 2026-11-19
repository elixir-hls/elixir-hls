defmodule EHLS.Compiler do
  @moduledoc false
  # What `use EHLS`, `defhls` and `definstance` do at compile time: the functions checked and made circuits, the
  # instances placed. Apart from EHLS, which holds what runs on the board (the helpers the generated code calls,
  # `subscribe`, `pack`), so that an application's pack carries none of this.

  # what the generated code calls at run time, and the compiler uses too
  import EHLS, only: [unsigned: 2, wrap: 3, layout: 1, packed_size: 1, runtime: 0]

  @compile {:no_warn_undefined, :hw_kernels}

  # a kernel's ports: values wider than this go in words
  @port 32

  def using(opts, caller) do
    packages =
      for entry <- Keyword.get(opts, :blocks, []) do
        case entry do
          {:{}, _, [m, o]} -> {Macro.expand(m, caller), o}
          {m, o} when is_list(o) -> {Macro.expand(m, caller), o}
          m -> {Macro.expand(m, caller), []}
        end
      end

    blocks = Enum.map(packages, &elem(&1, 0))
    EHLS.Backend.check!()
    EHLS.Blocks.check_soc!(blocks)
    peripherals = EHLS.Blocks.peripherals(blocks, Keyword.get(opts, :peripherals, []))

    # also without an output directory, so that options that cannot work stop the compile
    pkgs = for {m, o} <- packages, do: EHLS.Blocks.describe(m, o)

    if dir = System.get_env("EHLS_OUT_DIR") do
      File.mkdir_p!(dir)
      base = inspect(caller.module) |> Macro.underscore() |> String.replace("/", "_")
      if pkgs != [], do: File.write!(Path.join(dir, base <> ".packages"), JSON.encode!(pkgs))

      if peripherals != [] do
        list = for {name, gw} <- peripherals, do: %{name: name, gateware: gw}
        File.write!(Path.join(dir, base <> ".peripherals"), JSON.encode!(list))
      end
    end

    # read by definstance while the module body expands
    Module.put_attribute(caller.module, :hw_blocks, blocks)
    Module.put_attribute(caller.module, :hw_block_tables, Map.new(pkgs, &{&1.gateware, &1.table}))

    quote do
      import Bitwise
      import EHLS, only: [defhls: 2, definstance: 2, definstance: 3, signed: 2, unsigned: 2]
      @before_compile EHLS
    end
  end


  def remember(caller, attr, entry) do
    defs = Module.get_attribute(caller.module, attr) || []
    entry = put_elem(entry, tuple_size(entry) - 1, unqualify(elem(entry, tuple_size(entry) - 1), caller))
    Module.put_attribute(caller.module, attr, [Tuple.insert_at(entry, tuple_size(entry), caller.line) | defs])
    nil
  end

  @stream_fns [:map, :filter, :transform, :zip_with, :chunk_every, :run]
  @agent_fns %{start_link: :ehls_agent, get_and_update: :ehls_get_and_update, update: :ehls_update, get: :ehls_get}

  # EHLS.Stream.map(...) (or through an alias of EHLS.Stream) is map(...): the functions of EHLS.Stream are written in a
  # pipe with or without their module. Those of EHLS.Agent are written with it, as Elixir's Agent's are: marked here
  defp unqualify(ast, caller) do
    Macro.prewalk(ast, fn
      {{:., _, [{:__aliases__, _, _} = mod, f]}, m, args} = call when is_list(args) ->
        case Macro.expand(mod, caller) do
          EHLS.Stream when f in @stream_fns -> {f, m, args}
          EHLS.Agent when is_map_key(@agent_fns, f) -> {Map.fetch!(@agent_fns, f), m, args}
          EHLS.PubSub when f in [:broadcast, :subscribe] -> {f, [{:ehls_pubsub, true} | m], args}
          # a module attribute's list read at an index: a table in the circuit
          Enum when f == :at and length(args) == 2 and elem(hd(args), 0) == :@ -> {:table, m, args}
          _ -> call
        end

      {:table, m, [{:@, _, _} | _]} ->
        raise CompileError,
          file: caller.file,
          line: m[:line] || caller.line,
          description: "table(@t, i): a module attribute's list is read as in Elixir, Enum.at(@t, i)"

      # topics are written with their module, as Phoenix.PubSub's
      {f, m, args} when f in [:broadcast, :subscribe] and is_list(args) ->
        if m[:ehls_pubsub] do
          {f, m, args}
        else
          raise CompileError,
            file: caller.file,
            line: m[:line] || caller.line,
            description: "#{f}(...): a topic's functions are written with their module, EHLS.PubSub.#{f}(...)"
        end

      other ->
        other
    end)
  end
  # Definitions wait for the end of the module (EHLS.__before_compile__/1): clauses of one function come together, and a
  # function can call one defined below it. Tables are read then too, so an attribute set twice has its last value.
  def before_compile(env) do
    defs = Enum.reverse(Module.get_attribute(env.module, :hw_defs) || [])
    instances = Enum.reverse(Module.get_attribute(env.module, :hw_instance_defs) || [])

    functions =
      EHLS.Error.compile(env.file, env.line, fn ->
        defs
        |> Enum.group_by(fn {head, _, _} -> head_name(head) end)
        |> then(&Enum.map(Enum.uniq_by(defs, fn {head, _, _} -> head_name(head) end), fn {head, _, line} ->
          {head_name(head), line, Map.fetch!(&1, head_name(head))}
        end))
        |> Enum.map(fn {name, line, clauses} ->
          {head, body} = EHLS.Error.compile(env.file, line, fn -> plain_form(name, EHLS.Syntax.merge(clauses), env.module) end)
          %{name: name, line: line, head: head, body: body}
        end)
      end)

    Module.put_attribute(env.module, :hw_all_fns, Enum.map(functions, & &1.name))
    {streams, words} = Enum.split_with(functions, &stream_head?(&1.head))

    # words first: a stream function's stages are known by then
    quoted =
      for f <- EHLS.Error.compile(env.file, env.line, fn -> callees_first(words) ++ callees_first(streams) end) do
        define(f.head, f.body, %{env | line: f.line})
      end

    # agents: `n = agent(init)` and its functions, written as transform with the agent's name (agents/2)
    instances =
      for {head, opts, chain, line} <- instances do
        EHLS.Error.compile(env.file, line, fn -> {head, opts, agents(chain, head, env), line} end)
      end

    # an agent with a name (EHLS.Agent.start_link(init, name: MyApp.Count)): a module of that name says where it is, so
    # that EHLS.Agent.get(MyApp.Count, fun) reads it from the CPU
    for {name, inst, n} <- Module.get_attribute(env.module, :hw_agent_names) || [] do
      mod = env.module

      EHLS.Error.compile(env.file, env.line, fn ->
        if Code.ensure_loaded?(name) or Module.open?(name),
          do: raise(ArgumentError, "EHLS.Agent.start_link(..., name: #{inspect(name)}): a module of that name is there already")

        Module.create(name, quote do
          @moduledoc false
          @doc false
          def __ehls_agent__, do: {unquote(mod), unquote(inst), unquote(n)}
        end, Macro.Env.location(env))
      end)
    end

    # where each instance runs: its on:, else the default (EHLS.placement/0). An instance of streams on the CPU is a
    # process, not a circuit (cpu_instance/5, cpu_level_instance/5); the others go on to the cut and the circuits.
    {cpu_instances, instances} =
      EHLS.Error.compile(env.file, env.line, fn ->
        instances
        |> Enum.map(fn {head, opts, chain, line} ->
          {name, _args} = EHLS.Pipeline.head!(head)
          place = Keyword.get(opts, :on, EHLS.placement())
          unless place in [:cpu, :fpga], do: raise(ArgumentError, "definstance #{name}: on: is :cpu or :fpga, not #{inspect(place)}")
          {place == :cpu, {head, Keyword.delete(opts, :on), chain, line}}
        end)
        |> Enum.split_with(&elem(&1, 0))
        |> then(fn {c, f} -> {Enum.map(c, &elem(&1, 1)), Enum.map(f, &elem(&1, 1))} end)
      end)

    # the instances of levels on the CPU, known to those in the FPGA (compiled first) as such: none can wire one in
    cpu_levels = for {h, _, _, _} <- cpu_instances, {n, a} = EHLS.Pipeline.head!(h), EHLS.Level.level?(a), do: {n, %{on: :cpu}}
    Module.put_attribute(env.module, :hw_levels, Map.merge(Map.new(cpu_levels), Module.get_attribute(env.module, :hw_levels) || %{}))

    # the instances of levels first: an instance wiring one in knows its type and initial value (a function on the CPU too)
    {lvls, instances} = Enum.split_with(instances, fn {head, _, _, _} -> EHLS.Level.level?(elem(EHLS.Pipeline.head!(head), 1)) end)

    placed_lvls =
      for {head, opts, chain, line} <- lvls do
        EHLS.Error.compile(env.file, line, fn -> instance(head, opts, chain, %{env | line: line}) end)
      end

    # a stage on: :cpu cuts its instance in two (EHLS.CpuStage); the driver's functions come with it, and the kernels made for
    # functions on the CPU with levels wired in (EHLS.Level.place, as in the FPGA). After the functions: a stage with state is
    # placed with its initial value, which needs the state's type
    {streams, drivers, cut_kernels} =
      EHLS.Error.compile(env.file, env.line, fn ->
        attr = fn k -> Module.get_attribute(env.module, k) end
        # a function's state: a stateful kernel's, or a plain function's second argument where it is placed with transform
        accs = for {f, %{params: [_, {_, spec} | _]}} <- attr.(:hw_fns) || %{}, into: %{}, do: {f, spec}
        states = Map.merge(accs, attr.(:hw_states) || %{})
        types = attr.(:hw_types) || %{}

        place = fn chain ->
          EHLS.Level.place(chain, attr.(:hw_fns) || %{}, attr.(:hw_levels) || %{}, inspect(env.module), &spec_ast/1, %{},
                           attr.(:hw_kernel_levels) || %{})
        end

        {is, ds, defs} =
          instances
          |> Enum.map(&EHLS.CpuStage.split(&1, env.module, states, types, place))
          |> Enum.reduce({[], [], []}, fn {i, d, k}, {is, ds, ks} -> {is ++ i, ds ++ d, ks ++ k} end)

        kernels =
          for {gname, head, body} <- Enum.uniq_by(defs, &elem(&1, 0)), gname not in (attr.(:hw_defhls) || []),
              do: define(head, body, env)

        {is, ds, kernels}
      end)

    # the module's instances of streams by name: called inside another, a wire to it (build/3)
    Module.put_attribute(env.module, :hw_stream_instances, for({head, _, _, _} <- streams, do: elem(EHLS.Pipeline.head!(head), 0)))

    placed =
      placed_lvls ++
        for {head, opts, chain, line} <- streams do
          caller = %{env | line: line}
          EHLS.Error.compile(env.file, line, fn -> instance(head, opts, chain, caller) end)
        end ++
        # the instances of levels first: one of streams wiring one in knows its type and initial value
        for {head, opts, chain, line} <- Enum.sort_by(cpu_instances, fn {h, _, _, _} -> not EHLS.Level.level?(elem(EHLS.Pipeline.head!(h), 1)) end) do
          caller = %{env | line: line}
          {name, args} = EHLS.Pipeline.head!(head)

          EHLS.Error.compile(env.file, line, fn ->
            if EHLS.Level.level?(args),
              do: cpu_level_instance(name, args, opts, chain, caller),
              else: cpu_instance(name, args, opts, chain, caller)
          end)
        end

    quote do
      unquote_splicing(quoted)
      unquote_splicing(cut_kernels)
      unquote_splicing(placed)
      unquote_splicing(drivers)
    end
  end

  # A defhls is written as plain Elixir: a function of an accumulator returns the tuple it returns, {output, next_acc}, as for
  # Stream.transform, and an output that may be missing is a list of at most one ({[y], acc} / {[], acc}). Which argument is
  # the state is said where the function is placed (transform, get_and_update: the kernel is made then, EHLS.Level.place),
  # except for a function that has a memory or returns a list: stateful from its definition, its second argument the state.
  # Such a function is given here the compiler's own form: the state's type marked, the result the output's, [y] / [] made
  # emit(y) / skip().
  defp plain_form(name, {head, body}, module) do
    if stream_head?(head) do
      {head, body}
    else
      {h, guard} = case head, do: ({:when, _, [h, g]} -> {h, g}; h -> {h, nil})
      {:"::", hm, [{^name, nm, params}, ret]} = h

      for p <- params do
        t = case p, do: ({:\\, _, [{:"::", _, [_, t]}, _]} -> t; {:"::", _, [_, t]} -> t; _ -> nil)
        if match?({:state, _, [_]}, t),
          do: raise(ArgumentError, "defhls #{name}: a state is an argument of its type (n :: u16) and the result {output, next_state}; transform(init, &#{name}/2) says it is the state")
      end

      if match?({:emit, _, [_]}, ret),
        do: raise(ArgumentError, "defhls #{name}: an output that may be missing is a list of at most one: :: {[type], state_type}, returning {[y], next} or {[], next}")

      Macro.prewalk(body, fn
        {f, _, a} when f in [:emit, :skip] and is_list(a) ->
          raise ArgumentError, "defhls #{name}: an output that may be missing is a list of at most one: {[y], next} or {[], next}"

        n ->
          n
      end)

      if Enum.any?(params, &match?({:"::", _, [_, {:memory, _, _}]}, &1)),
        do: raise(ArgumentError, "defhls #{name}: a memory is a tuple in the state: {pos, hist} :: {u8, tuple(s16, 256)}, elem(hist, i), put_elem(hist, i, v)")

      listed? = match?({[_], _}, ret)
      ret_o = case ret, do: ({[o], st} -> {o, st}; r -> r)

      # a function whose state holds a tuple: kept as written, for a memory where it is placed
      # (transform(init, &f/2, memory: [:h]), EHLS.Level and EHLS.TupleState)
      # the state is the second argument (Stream.transform's function); a chunk, w :: tuple(t, n), is no state
      state = Enum.at(params, 1)
      tuple_state? = state != nil and tuple_typed?(state)

      # its source, for memory: where it is placed; a whole state of one type written out, {s16, s16, s16}, is one too
      if tuple_state? or one_type_state?(state) do
        tuples = Module.get_attribute(module, :hw_tuple_sources) || %{}
        Module.put_attribute(module, :hw_tuple_sources,
          Map.put(tuples, name, %{params: params, ret: ret, ret_o: ret_o, body: body, guard: guard, listed?: listed?}))
      end

      # a pattern in the head ({pos, hist} :: {u8, tuple(s16, 8)}): one variable, matched at the start of the body
      {params, body} = unpattern(params, body)
      head = {:"::", hm, [{name, nm, params}, ret]}
      head = if guard, do: {:when, [], [head, guard]}, else: head
      # a function whose state holds a tuple is a plain function, its output a list or not: its kernel is made where it
      # is placed (with transform, its state in registers, or with memory: as EHLS.TupleState makes it)
      if tuple_state?, do: {head, body}, else: plain_form_state(name, head, body, h, hm, nm, params, ret, guard, listed?)
    end
  end

  defp one_type_state?({:"::", _, [_, t]}) do
    case tuple_items(t) do
      [a | _] = ts -> length(ts) > 1 and Enum.all?(ts, &(&1 == a or Macro.to_string(&1) == Macro.to_string(a))) and tuple_items(a) == []
      [] -> false
    end
  end

  defp one_type_state?(_), do: false

  # a state holding a tuple: tuple(t, n), or a tuple written out inside the state's tuple, {pos, {s16, s16, s16}}
  defp tuple_typed?({:"::", _, [_, t]}), do: has_tuple_n?(t) or Enum.any?(tuple_items(t), &(tuple_items(&1) != []))
  defp tuple_typed?(_), do: false

  defp tuple_items({a, b}), do: [a, b]
  defp tuple_items({:{}, _, ts}), do: ts
  defp tuple_items(_), do: []

  defp has_tuple_n?(t), do: elem(Macro.prewalk(t, false, fn {:tuple, _, [_, _]} = n, _ -> {n, true}; n, a -> {n, a} end), 1)

  defp unpattern(params, body) do
    {params, binds} =
      params
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {{:"::", _, [{v, _, c}, _]} = p, _}, acc when is_atom(v) and is_atom(c) ->
          {p, acc}

        {{:"::", m, [pat, t]}, k}, acc ->
          var = {:"hw__p#{k}", [], nil}
          {{:"::", m, [var, t]}, acc ++ [{:=, [], [pat, var]}]}

        {p, _}, acc ->
          {p, acc}
      end)

    body =
      case {binds, body} do
        {[], b} -> b
        {bs, {:__block__, m, es}} -> {:__block__, m, bs ++ es}
        {bs, b} -> {:__block__, [], bs ++ [b]}
      end

    {params, body}
  end

  @doc false
  # an output that may be missing, as the circuit gives it: {[y], s} is {emit(y), s}, {[], s} is {skip(), s}
  def listed_out(body) do
    Macro.prewalk(body, fn
      {[], s} -> {{:skip, [], []}, s}
      {[y], s} -> {{:emit, [], [y]}, s}
      n -> n
    end)
  end

  defp plain_form_state(name, head, body, _h, hm, nm, params, ret, guard, listed?) do
      if listed? do
        {out, state_t} =
          case ret do
            {[o], st} -> {{:emit, [], [o]}, st}
            {o, st} -> {o, st}
            _ -> raise ArgumentError, "defhls #{name}: with a memory, the result is {output, next_state}"
          end

        params =
          case params do
            [x, {:"::", pm, [sv, t]} | rest] ->
              unless Macro.to_string(t) == Macro.to_string(state_t),
                do: raise(ArgumentError, "defhls #{name}: the state #{Macro.to_string(sv)} is #{Macro.to_string(t)} and the result gives #{Macro.to_string(state_t)} as the next one")

              [x, {:"::", pm, [sv, {:state, [], [t]}]} | rest]

            _ ->
              raise ArgumentError, "defhls #{name}: the second argument is the state (a memory or a list in the result needs one)"
          end

        body = if listed?, do: listed_out(body), else: body

        h = {:"::", hm, [{name, nm, params}, out]}
        {if(guard, do: {:when, [], [h, guard]}, else: h), body}
      else
        {head, body}
      end
  end

  # An agent (EHLS.Agent, as Elixir's Agent): `{:ok, n} = EHLS.Agent.start_link(init)` one state;
  # `x |> EHLS.Agent.get_and_update(n, &f/2)` each element through f(x, state) -> {output, next state}, its output going
  # on; `EHLS.Agent.update(n, &f/2)` the same, ending the pipe (marked :ehls_agent, :ehls_get_and_update, :ehls_update by
  # unqualify). Written here as transform(init, &f/2, agent: n), the first also name: n when the agent has a name (EHLS.Agent.get(Name, fun),
  # `inst(:state, :n)`): the circuit shares one state among them (hls_litex Agent), one element at a time.
  defp agents(chain, head, env) do
    module = env.module
    exprs = case chain, do: ({:__block__, _, es} -> es; e -> [e])

    for e <- exprs do
      Macro.prewalk(e, fn
        {f, _, args} when f in [:agent, :get_and_update, :update] and is_list(args) ->
          what = if f == :agent, do: "start_link", else: f
          raise ArgumentError, "definstance: #{f}(...): an agent's functions are written with their module, EHLS.Agent.#{what}(...)"

        {:=, _, [{_, _, c}, {:ehls_agent, _, _}]} when is_atom(c) ->
          raise ArgumentError, "definstance: EHLS.Agent.start_link(initial) gives {:ok, agent}: {:ok, n} = EHLS.Agent.start_link(initial)"

        n ->
          n
      end)
    end

    {decls, rest} =
      Enum.split_with(exprs, &match?({:=, _, [{:ok, {_, _, c}}, {:ehls_agent, _, [_ | _]}]} when is_atom(c), &1))

    {inst, _} = EHLS.Pipeline.head!(head)

    # the agents with a name are read from the CPU: the circuit for reading them is made
    readable =
      for {:=, _, [{:ok, {n, _, _}}, {:ehls_agent, _, [_ | opts]}]} <- decls, into: MapSet.new() do
      case opts do
        [] ->
          nil

        [[name: alias]] ->
          name = Macro.expand(alias, env)

          unless is_atom(name) and String.starts_with?(Atom.to_string(name), "Elixir."),
            do: raise(ArgumentError, "definstance: EHLS.Agent.start_link(initial, name: Name): the name is a module name, as MyApp.Count")

          names = Module.get_attribute(module, :hw_agent_names) || []
          Module.put_attribute(module, :hw_agent_names, names ++ [{name, inst, n}])
          n

        other ->
          raise ArgumentError, "definstance: EHLS.Agent.start_link(initial, name: Name), got the options #{Macro.to_string(other)}"
      end
    end
    |> MapSet.delete(nil)

    if decls == [] do
      for e <- exprs, uses_agent?(e),
          do: raise(ArgumentError, "definstance: EHLS.Agent.get_and_update / update need an agent: {:ok, n} = EHLS.Agent.start_link(initial)")

      chain
    else
      table = Map.new(decls, fn {:=, _, [{:ok, {n, _, _}}, {:ehls_agent, _, [init | _]}]} -> {n, init} end)
      # a function's state: a kernel's (a memory or a list in its result), or a plain function's second argument
      fns = Module.get_attribute(module, :hw_fns) || %{}

      states =
        Map.merge(
          for({f, %{params: [_, {_, s} | _]}} <- fns, into: %{}, do: {f, s}),
          Module.get_attribute(module, :hw_states) || %{}
        )

      for {n, _} <- table, not Enum.any?(rest, &uses?(&1, n)),
          do: raise(ArgumentError, "definstance: the agent #{n} is used by no EHLS.Agent.get_and_update / update")
      # named: the agents whose first function is written (it carries name:); their state types, %{n => {f, spec}}
      {rest, _} =
        Enum.map_reduce(rest, {MapSet.new(), %{}}, fn e, named ->
          # from the outside in: the pipe ending in update before update itself
          Macro.prewalk(e, named, fn
            {:|>, m, [lhs, {:ehls_update, um, args}]}, named ->
              {t, named} = agent_stage(um, args, {table, readable}, states, named, "update")
              {{:|>, m, [{:|>, m, [lhs, t]}, {:run, um, []}]}, named}

            {:ehls_get_and_update, m, args}, named ->
              agent_stage(m, args, {table, readable}, states, named, "get_and_update")

            {:ehls_update, _, [_, _]}, _named ->
              raise ArgumentError, "definstance: EHLS.Agent.update(agent, &f/2) ends a pipe: x |> EHLS.Agent.update(n, &f/2)"

            {:ehls_get, _, [{n, _, c} | _]}, _named when is_atom(c) and is_map_key(table, n) ->
              raise ArgumentError, "definstance: EHLS.Agent.get(#{n}, ...), an agent's state as a level, is not there yet"

            node, named ->
              {node, named}
          end)
        end)


      case rest, do: ([e] -> e; es -> {:__block__, [], es})
    end
  end

  defp agent_stage(m, [{n, _, c}, f], {table, readable}, states, named, what) when is_atom(c) do
    init = Map.get(table, n) || raise(ArgumentError, "definstance: EHLS.Agent.#{what}(#{n}, ...): #{n} is no agent of this instance ({:ok, n} = EHLS.Agent.start_link(initial))")

    fun =
      case f do
        {:&, _, [{:/, _, [{g, _, _}, 2]}]} when is_atom(g) -> g
        _ -> raise ArgumentError, "definstance: EHLS.Agent.#{what}(#{n}, &f/2): f a defhls of the element and the state"
      end

    spec = Map.get(states, fun) || raise(ArgumentError, "definstance: EHLS.Agent.#{what}(#{n}, &#{fun}/2): #{fun} takes no state")

    {named, specs} = named

    # the agent's functions all take the one state
    case Map.get(specs, n) do
      nil -> :ok
      {_, ^spec} -> :ok
      {other, s} -> raise ArgumentError, "definstance: #{fun} and #{other} share the agent #{n}, but their states are #{EHLS.type_name(spec)} and #{EHLS.type_name(s)}"
    end

    opts = if MapSet.member?(named, n) or not MapSet.member?(readable, n), do: [agent: n], else: [agent: n, name: n]
    {{:transform, m, [init, f, opts]}, {MapSet.put(named, n), Map.put_new(specs, n, {fun, spec})}}
  end

  defp agent_stage(_m, args, _tables, _states, _named, what),
    do: raise(ArgumentError, "definstance: EHLS.Agent.#{what}(agent, &f/2), got EHLS.Agent.#{what}(#{Enum.map_join(args, ", ", &Macro.to_string/1)})")

  defp uses_agent?(e),
    do: elem(Macro.prewalk(e, false, fn {f, _, _} = n, _acc when f in [:ehls_get_and_update, :ehls_update] -> {n, true}; n, acc -> {n, acc} end), 1)

  defp uses?(e, n),
    do: elem(Macro.prewalk(e, false, fn {f, _, [{^n, _, _} | _]} = x, _acc when f in [:ehls_get_and_update, :ehls_update] -> {x, true}; x, acc -> {x, acc} end), 1)

  defp head_name({:when, _, [h, _]}), do: head_name(h)
  defp head_name({:"::", _, [{name, _, _}, _]}) when is_atom(name), do: name
  defp head_name(head), do: elem(parse_head(head), 0)

  # in source order, each after the functions it calls
  defp callees_first(functions) do
    by_name = Map.new(functions, &{&1.name, &1})
    {order, _} = Enum.reduce(functions, {[], MapSet.new()}, fn f, acc -> visit(f, by_name, [], acc) end)
    Enum.reverse(order)
  end

  defp visit(f, by_name, path, {order, done}) do
    cond do
      f.name in done ->
        {order, done}

      f.name in path ->
        EHLS.Error.at(f.line, fn ->
          raise ArgumentError, "defhls #{f.name}: it calls itself, through #{Enum.join(path, ", ")}: a circuit has a fixed size"
        end)

      true ->
        callees = called(f.body, by_name) -- [f.name]
        {order, done} = Enum.reduce(callees, {order, done}, &visit(Map.fetch!(by_name, &1), by_name, [f.name | path], &2))
        {[f | order], MapSet.put(done, f.name)}
    end
  end

  defp called(body, by_name) do
    {_, names} =
      Macro.prewalk(body, [], fn
        {f, _, args} = n, acc when is_atom(f) and is_list(args) ->
          {n, if(Map.has_key?(by_name, f), do: [f | acc], else: acc)}

        n, acc ->
          {n, acc}
      end)

    names |> Enum.uniq() |> Enum.reverse()
  end

  defp instance(head, opts, chain, caller) do
    {name, args} = EHLS.Pipeline.head!(head)

    if EHLS.Level.level?(args),
      do: level_instance(name, args, opts, chain, caller),
      else: stream_instance(name, args, opts, chain, caller)
  end

  # An instance of streams placed on the CPU (EHLS.Pipeline, "Placement"): its body compiled to code over lists, one
  # list per stream for each call, the stages' states (and a join's waiting elements, a hold's value) kept between calls
  # by a process (EHLS.CpuInstance). Each pipe between joins is analysed as a circuit's is (cpu_segment/4) and run as a
  # stream function runs on lists. A stream named and used twice is a fork: the same list to both. Not yet: blocks
  # other than ticks, hold and run, instances called inside, a pin's level, on: :fpga inside.
  # inst(:get, n), behind EHLS.Agent.get(Name, fun): the state of each agent of the instance with a name; any other
  # is not read (no circuit reads it)
  defp agent_gets(inst, caller) do
    readable = for {_, ^inst, n} <- Module.get_attribute(caller.module, :hw_agent_names) || [], do: n

    gets =
      for n <- readable do
        quote do
          def unquote(inst)(:get, unquote(n)), do: unquote(inst)(:state, unquote(n))
        end
      end

    quote do
      unquote_splicing(gets)

      def unquote(inst)(:get, agent) when is_atom(agent) do
        raise ArgumentError,
              "#{unquote(inst)}(:get, #{inspect(agent)}): no agent read from the CPU is #{inspect(agent)}; an agent is read " <>
                "when it has a name, EHLS.Agent.start_link(initial, name: Name), with EHLS.Agent.get(Name, fun)"
      end
    end
  end

  defp cpu_instance(name, args, opts, body, caller) do
    module = inspect(caller.module)
    key = String.to_atom("#{module}.#{name}")
    not_yet = fn what -> raise ArgumentError, "definstance #{name}: #{what} does not run on the CPU yet: place it in the FPGA (on: :fpga)" end

    if name in (Module.get_attribute(caller.module, :hw_all_fns) || []),
      do: raise(ArgumentError, "definstance #{name}: a defhls of this module has that name; the name tells an instance from a function")

    for {k, _} <- opts, k not in [:buffer, :overflow], do: raise(ArgumentError, "definstance #{name}: unknown option #{k}")

    unless Keyword.get(opts, :overflow, :wait) in [:wait, :drop],
      do: raise(ArgumentError, "definstance #{name}: overflow is :wait or :drop, got #{inspect(Keyword.get(opts, :overflow))}")

    arg_names =
      for a <- args do
        case a do
          {v, _, c} when is_atom(v) and is_atom(c) -> v
          _ -> raise ArgumentError, "definstance #{name}: an argument of an instance of streams is a name"
        end
      end

    exprs =
      case cpu_stages!(body, name) do
        {:__block__, _, es} -> es
        e -> [e]
      end

    # every join made explicit, as for the circuit; a name given to a stream counts as a stream after it
    {exprs, _} =
      Enum.map_reduce(exprs, MapSet.new(arg_names), fn
        {:=, _, [{y, _, c}, e]}, streams when is_atom(y) and is_atom(c) -> {{y, EHLS.Join.normalize(e, streams)}, MapSet.put(streams, y)}
        e, streams -> {{nil, EHLS.Join.normalize(e, streams)}, streams}
      end)

    inputs = Map.new(arg_names, fn a -> {a, Macro.unique_var(:"hw_in_#{a}", __MODULE__)} end)

    env = %{name: name, key: key, module: module, caller: caller, not_yet: not_yet, args: arg_names,
            cpu: Module.get_attribute(caller.module, :hw_cpu) || %{}}

    ctx = %{steps: [], svars: [], firsts: [], reads: [], kernels: [], vars: Map.new(inputs, fn {a, v} -> {a, {:arg, v}} end),
            used: MapSet.new(), in_types: %{}, source: nil, src_var: Macro.unique_var(:hw_src, __MODULE__),
            exact: MapSet.new(), agents: %{}}

    last = length(exprs) - 1

    {output, ctx} =
      exprs
      |> Enum.with_index()
      |> Enum.reduce({nil, ctx}, fn {{y, e}, i}, {_, ctx} ->
        {res, ctx} = cpu_expr(e, env, ctx)

        ctx =
          case {y, res} do
            {nil, _} -> ctx
            {y, {:list, v, t}} -> %{ctx | vars: Map.put(ctx.vars, y, {:named, v, t})}
            {y, :sunk} -> raise ArgumentError, "definstance #{name}: #{y} = ... ends in a sink: there is no stream to name"
          end

        if i < last and y == nil and res != :sunk,
          do: raise(ArgumentError, "definstance #{name}: only the last expression goes to the CPU; one before it ends in a sink (hold, run) or names its stream (y = ...)")

        {res, ctx}
      end)

    for a <- arg_names, a not in ctx.used, do: raise(ArgumentError, "definstance #{name}: nothing happens to #{a}")
    if arg_names == [] and ctx.source == nil, do: raise(ArgumentError, "definstance #{name}: an instance without an argument starts with a source (ticks)")

    {out_var, out_spec} =
      case output do
        {:list, v, t} -> {v, t}
        _ -> {nil, nil}
      end

    if match?({:arg, _}, out_spec), do: raise(ArgumentError, "definstance #{name}: nothing happens to its argument")
    output? = out_var != nil
    source = ctx.source
    svars = ctx.svars
    in_layouts = for a <- arg_names, do: Macro.escape(layout(Map.fetch!(ctx.in_types, a)))
    out_layout = Macro.escape(if output?, do: layout(out_spec), else: 32)
    pack = runtime() || EHLS
    y = Macro.unique_var(:hw_y, __MODULE__)

    # what the step takes: one list, a tuple of lists for several arguments, or the counts of a source
    input_pattern =
      case arg_names do
        [] -> ctx.src_var
        [a] -> Map.fetch!(inputs, a)
        as -> {:{}, [], Enum.map(as, &Map.fetch!(inputs, &1))}
      end

    # the output wrapped to its type, unless it is already: what the NIF stages give is unpacked as that type (and on
    # 32-bit AtomVM a wrap to 32 bits works on a boxed integer, the most of a NIF call's time)
    result =
      cond do
        not output? -> []
        MapSet.member?(ctx.exact, out_var) -> out_var
        true -> quote(do: :lists.map(fn unquote(y) -> unquote(wrap_code(y, out_spec)) end, unquote(out_var)))
      end

    reads =
      ctx.reads ++
        [quote do
           def unquote(:"__cpu_read_#{name}__")(_states, what, n),
             do: :erlang.error({if(what == :value, do: :no_hold_stage, else: :no_named_state), unquote(key), n})
         end]

    datas = Macro.generate_arguments(length(arg_names), __MODULE__)

    data_calls =
      if arg_names == [] do
        []
      else
        guard = Enum.reduce(datas, true, fn d, acc -> quote(do: unquote(acc) and (is_list(unquote(d)) or is_binary(unquote(d)))) end)
        lists = for {d, l} <- Enum.zip(datas, in_layouts), do: quote(do: if(is_binary(unquote(d)), do: unquote(pack).unpack(unquote(d), unquote(l)), else: unquote(d)))
        arg = if length(datas) == 1, do: hd(lists), else: {:{}, [], lists}

        [quote do
           # a list in, a list out; a binary in, a binary out (as: says otherwise); the states go on. With several
           # arguments, one list or binary for each, their elements taken together as they come
           def unquote(name)(unquote_splicing(datas)) when unquote(guard), do: unquote(name)(unquote_splicing(datas), [])

           def unquote(name)(unquote_splicing(datas), opts) when unquote(guard) and is_list(opts) do
             case EHLS.CpuInstance.call(unquote(key), __MODULE__, unquote(name), unquote(arg), opts) do
               {:ok, out} ->
                 if unquote(output?) do
                   case EHLS.CpuInstance.opt(opts, :as, if(is_binary(unquote(hd(datas))), do: :binary, else: :list)) do
                     :list -> out
                     :binary -> unquote(pack).pack(out, unquote(out_layout))
                   end
                 else
                   # it ends in a sink: nothing comes back, as from an instance in the FPGA
                   :ok
                 end

               error ->
                 error
             end
           end
         end]
      end

    quote do
      unquote_splicing(ctx.kernels)

      @doc false
      def unquote(:"__cpu_step_#{name}__")(unquote(input_pattern), {unquote_splicing(svars)}) do
        unquote_splicing(ctx.steps)
        {unquote(result), {unquote_splicing(svars)}}
      end

      @doc false
      def unquote(:"__cpu_init_#{name}__")(), do: {unquote_splicing(ctx.firsts)}

      @doc false
      def unquote(:"__cpu_source_#{name}__")(), do: unquote(Macro.escape(source))

      @doc false
      def unquote(:"__cpu_buffer_#{name}__")(), do: unquote(if Keyword.get(opts, :buffer, 0) > 0, do: Keyword.get(opts, :buffer), else: 4096)

      @doc false
      def unquote(:"__cpu_overflow_#{name}__")(), do: unquote(Keyword.get(opts, :overflow, :wait))

      @doc false
      def unquote(:"__cpu_pack_#{name}__")(list), do: unquote(pack).pack(list, unquote(out_layout))

      @doc false
      unquote_splicing(reads)

      # the latest element that reached hold(h); the state of transform(.., name: n)
      def unquote(name)(:value, h) when is_atom(h), do: EHLS.CpuInstance.read(unquote(key), __MODULE__, unquote(name), [:value, h])
      def unquote(name)(:state, n) when is_atom(n), do: EHLS.CpuInstance.read(unquote(key), __MODULE__, unquote(name), [:state, n])
      # an agent's state, as Agent.get: only of an agent with a name (the circuit to read it is made for those)
      unquote(agent_gets(name, caller))

      def unquote(name)(:start), do: EHLS.CpuInstance.control(unquote(key), __MODULE__, unquote(name), :start)
      def unquote(name)(:stop), do: EHLS.CpuInstance.control(unquote(key), __MODULE__, unquote(name), :stop)

      unquote_splicing(if source, do: source_calls(name, key, output?, pack, out_layout), else: [])
      unquote_splicing(data_calls)
    end
  end

  # One expression of an instance on the CPU: {:list, var, type} (a stream: the variable holding its list for this call,
  # its element type, or {:arg, a} while an argument's type is not known), or :sunk; and the context with its code.
  defp cpu_expr({v, _, c}, env, ctx) when is_atom(v) and is_atom(c) do
    case Map.fetch(ctx.vars, v) do
      {:ok, {:arg, var}} ->
        if v in ctx.used,
          do: raise(ArgumentError, "definstance #{env.name}: #{v} goes in twice: to use it twice, name what it gives (y = #{v} |> f())")

        {{:list, var, {:arg, v}}, %{ctx | used: MapSet.put(ctx.used, v)}}

      {:ok, {:named, var, t}} ->
        {{:list, var, t}, ctx}

      :error ->
        raise ArgumentError, "definstance #{env.name}: #{v} is neither an argument nor a stream named before"
    end
  end

  # a join: one element of each side, together, through f; what one side has more waits for the next call
  defp cpu_expr({:zip_with, m, [a, b, fun]}, env, ctx) do
    EHLS.Error.at(m[:line], fn ->
      f =
        case fun do
          {:&, _, [{:/, _, [{f, _, _}, 2]}]} when is_atom(f) -> f
          other -> raise ArgumentError, "definstance #{env.name}: zip_with takes &f/2, not #{Macro.to_string(other)}"
        end

      {ra, ctx} = cpu_expr(a, env, ctx)
      {rb, ctx} = cpu_expr(b, env, ctx)

      for r <- [ra, rb], r == :sunk, do: raise(ArgumentError, "definstance #{env.name}: a side of zip_with ends in a sink")

      %{params: [{_, ta}, {_, tb}], ret: ret} =
        Map.get(Module.get_attribute(env.caller.module, :hw_fns) || %{}, f) ||
          raise(ArgumentError, "definstance #{env.name}: zip_with's #{f} is not a defhls of two arguments of #{env.module}")

      {:list, la, ka} = ra
      {:list, lb, kb} = rb
      ctx = ctx |> cpu_type(ka, ta, f, env) |> cpu_type(kb, tb, f, env)
      qa = Macro.unique_var(:hw_qa, __MODULE__)
      qb = Macro.unique_var(:hw_qb, __MODULE__)
      out = Macro.unique_var(:hw_zip, __MODULE__)
      x = Macro.unique_var(:hw_x, __MODULE__)
      yv = Macro.unique_var(:hw_y, __MODULE__)

      step =
        quote do
          {unquote(out), unquote(qa), unquote(qb)} =
            EHLS.CpuInstance.zip_with(unquote(qa) ++ unquote(la), unquote(qb) ++ unquote(lb), fn unquote(x), unquote(yv) -> unquote(f)(unquote(x), unquote(yv)) end)
        end

      {{:list, out, ret}, %{ctx | steps: ctx.steps ++ [step], svars: ctx.svars ++ [qa, qb], firsts: ctx.firsts ++ [[], []]}}
    end)
  end

  defp cpu_expr(e, env, ctx) do
    [head | stages] = unpipe_stages(e)

    {r, ctx} =
      case head do
        {:ticks, _, [rate]} when is_integer(rate) and rate > 0 ->
          if env.args != [] or ctx.source != nil,
            do: env.not_yet.("a source besides the instance's argument, or two sources")

          {{:list, ctx.src_var, {32, false}}, %{ctx | source: {:ticks, rate}}}

        {:ticks, _, _} ->
          raise ArgumentError, "definstance #{env.name}: ticks(rate), rate a positive integer (per second)"

        {v, _, c} when is_atom(v) and is_atom(c) ->
          cpu_expr(head, env, ctx)

        {:zip_with, _, _} ->
          cpu_expr(head, env, ctx)

        {s, _, _} ->
          env.not_yet.("the source #{s}")
      end

    {stages, sink} =
      case List.last(stages) do
        {:hold, _, [h]} when is_atom(h) -> {Enum.drop(stages, -1), {:hold, h}}
        {:run, _, []} -> {Enum.drop(stages, -1), :run}
        _ -> {stages, nil}
      end

    {:list, in_var, in_type} = r

    {res, ctx} =
      if stages == [] do
        {r, ctx}
      else
        cpu_segment(repipe_stages([{:hw__seg, [], nil} | stages]), in_var, in_type, env, ctx)
      end

    case {sink, res} do
      {nil, _} ->
        {res, ctx}

      {:run, _} ->
        {:sunk, ctx}

      {{:hold, h}, {:list, v, t}} ->
        if match?({:arg, _}, t), do: raise(ArgumentError, "definstance #{env.name}: hold(#{h}) of an argument: put a function before it")
        hv = Macro.unique_var(:hw_hold, __MODULE__)
        step = quote(do: unquote(hv) = if(unquote(v) == [], do: unquote(hv), else: :lists.last(unquote(v))))
        pos = length(ctx.svars) + 1

        read =
          quote do
            def unquote(:"__cpu_read_#{env.name}__")(states, :value, unquote(h)), do: :erlang.element(unquote(pos), states)
          end

        {:sunk, %{ctx | steps: ctx.steps ++ [step], svars: ctx.svars ++ [hv], firsts: ctx.firsts ++ [Macro.escape(zero_value(t))], reads: ctx.reads ++ [read]}}
    end
  end

  # what a stream gives into what takes it: an argument gets the type of what takes it; a known type must keep its
  # values there (a widening), as at a link of the circuit
  defp cpu_type(ctx, {:arg, a}, spec, _f, _env), do: %{ctx | in_types: Map.put(ctx.in_types, a, spec)}

  defp cpu_type(ctx, given, spec, f, env) do
    unless given == :any or spec == :any or EHLS.Pipeline.widens?(given, spec),
      do: raise(ArgumentError, "definstance #{env.name}: #{type_name(given)} goes into #{f}, which takes #{type_name(spec)}: that would change the value")

    ctx
  end

  # A pipe of functions between joins (`hw__seg |> map(&f/1) |> ...`), analysed as a circuit's is and run as a stream
  # function runs on lists, from the list in `in_var`, each stage with state from its state variable.
  defp cpu_segment(chain, in_var, in_type, env, ctx) do
    %{name: name, caller: caller, not_yet: not_yet, module: module} = env
    packages = Module.get_attribute(caller.module, :hw_blocks) || []
    blocks = EHLS.Blocks.table(packages)
    windows = Module.get_attribute(caller.module, :hw_windows) || %{}
    known = Module.get_attribute(caller.module, :hw_stream_fns) || %{}
    all_fns = Module.get_attribute(caller.module, :hw_all_fns) || []
    others = Module.get_attribute(caller.module, :hw_stream_instances) || []

    chain = chain |> EHLS.Pipeline.stream_body!(name, :hw__seg) |> EHLS.Pipeline.expand(known)

    for {b, _, a} <- unpipe_stages(chain) do
      cond do
        is_list(a) and Enum.any?(a, &stream_ref?/1) -> not_yet.("a join inside #{b}")
        b in others or match?({:__aliases__, _, _}, b) -> not_yet.("an instance called inside (#{b})")
        # the packages' blocks, and the SoC's built-in ones by name (they are in the table only with a SoC backend)
        (Map.has_key?(blocks, b) or b in [:ticks, :hold, :run]) and b not in all_fns and not Map.has_key?(windows, b) ->
          not_yet.("the block #{b} in the middle of a pipe")
        true -> :ok
      end
    end

    hls_fns = Module.get_attribute(caller.module, :hw_defhls) || []

    # filter(&f/1): a kernel made for it, as in the FPGA
    {chain, filtered} = EHLS.Pipeline.filters(chain, Module.get_attribute(caller.module, :hw_fns) || %{}, &spec_ast/1)

    {placed_chain, at_levels} =
      EHLS.Level.place(chain, Module.get_attribute(caller.module, :hw_fns) || %{}, Module.get_attribute(caller.module, :hw_levels) || %{},
                       module, &spec_ast/1, %{}, Module.get_attribute(caller.module, :hw_kernel_levels) || %{})

    # generated kernels (a filter's, a level's, a window's) are defined once in the module, however many segments use them
    defined_already = Module.get_attribute(caller.module, :hw_cpu_defined) || MapSet.new()
    at_levels = filtered ++ at_levels
    level_kernels = for {gname, head, kbody} <- Enum.uniq_by(at_levels, &elem(&1, 0)), gname not in hls_fns, gname not in defined_already,
                        do: define(head, kbody, caller)
    hls_fns = hls_fns ++ Enum.map(at_levels, &elem(&1, 0))
    {fused, generated, gen_names} = EHLS.Pipeline.fuse(placed_chain, windows)
    window_kernels = window_kernels(generated, caller)
    # read after the kernels are defined: theirs are in it then
    cpu = Module.get_attribute(caller.module, :hw_cpu) || %{}
    Module.put_attribute(caller.module, :hw_cpu_defined, MapSet.union(defined_already, MapSet.new(Enum.map(at_levels, &elem(&1, 0)) ++ gen_names)))
    states = Map.drop(Module.get_attribute(caller.module, :hw_states) || %{}, gen_names)
    stages = EHLS.Pipeline.stages(fused, caller.module, hls_fns ++ gen_names, states, blocks, true)
    types = EHLS.Pipeline.types!(stages, Module.get_attribute(caller.module, :hw_types) || %{}, EHLS.Blocks.types(packages))
    {in_spec, _} = hd(types)
    {_, out_spec} = List.last(types)
    ctx = cpu_type(ctx, in_type, in_spec, hd(stages).name, env)
    list = Macro.unique_var(:hw_list, __MODULE__)
    xv = Macro.unique_var(:hw_x, __MODULE__)
    ctx = %{ctx | steps: ctx.steps ++ [quote(do: unquote(list) = unquote(in_var))], kernels: ctx.kernels ++ level_kernels ++ window_kernels}

    if EHLS.cpu_code() == :nif do
      cpu_segment_nif(stages, types, fused, states, cpu, list, env, ctx)
    else
      cpu_segment_elixir(stages, fused, cpu, list, xv, out_spec, env, ctx)
    end
  end

  # what a level wired into a stage is on the CPU: an integer, or g(:value) read at the call
  defp cpu_defaults(stage, info, not_yet) do
    case stage[:wires] do
      nil ->
        info.args

      wires ->
        for w <- wires do
          cond do
            Map.has_key?(w, :const) ->
              w.const

            Map.has_key?(w, :from) ->
              [mod, lname] = String.split(w.from, ~r/\.(?=[^.]+$)/)
              quote(do: apply(unquote(Module.concat([mod])), unquote(String.to_atom(lname)), [:value]))

            true ->
              not_yet.("a pin wired into #{stage.name}")
          end
        end
    end
  end

  # the levels read once per call, before the stage, not for every element: {binds, values}
  defp cpu_binds(defaults) do
    {binds, defaults} =
      defaults
      |> Enum.map(fn
        d when is_integer(d) ->
          {nil, d}

        d ->
          v = Macro.unique_var(:hw_lv, __MODULE__)
          {quote(do: unquote(v) = unquote(d)), v}
      end)
      |> Enum.unzip()

    {Enum.reject(binds, &is_nil/1), defaults}
  end

  # The stages as C (cpu: :nif): the list packed once, each stage's kernel run on the bytes through the runtime's NIF
  # (EHLS.NIFRun, in chunks), its state a binary; where one stage gives another type than the next takes (a widening
  # the circuit does for free) the elements are packed again; the bytes made a list at the end.
  defp cpu_segment_nif(stages, types, fused, states, cpu, list, env, ctx) do
    %{name: name, module: module, not_yet: not_yet} = env
    pack = runtime() || raise(ArgumentError, "definstance #{name}: cpu: :nif runs the stages through a runtime backend's NIF (EHLS_RUNTIME=atomvm)")
    bin = Macro.unique_var(:hw_bin, __MODULE__)
    {first_in, _} = hd(types)
    ctx = %{ctx | steps: ctx.steps ++ [quote(do: unquote(bin) = unquote(pack).pack(unquote(list), unquote(Macro.escape(layout(first_in)))))]}

    {ctx, last_out} =
      Enum.zip([stages, types, EHLS.Pipeline.initial_states(fused)])
      |> Enum.reduce({ctx, nil}, fn {stage, {tin, tout}, init}, {ctx, prev_out} ->
        info = Map.fetch!(cpu, stage.name)
        {binds, defaults} = cpu_binds(cpu_defaults(stage, info, not_yet))

        repack =
          if prev_out != nil and layout(prev_out) != layout(tin),
            do: [quote(do: unquote(bin) = unquote(pack).pack(unquote(pack).unpack(unquote(bin), unquote(Macro.escape(layout(prev_out)))), unquote(Macro.escape(layout(tin)))))],
            else: []

        if stage[:agent], do: not_yet.("an agent's functions as C (cpu: :nif)")
        kernel = String.to_atom("#{module}.#{stage.name}")
        # a NIF state word holds 64 bits; a state is up to 32 (defhls says so), so this is the value as the circuit's
        words = if info.state? and init != nil, do: EHLS.__init_words__(init, Map.fetch!(states, stage.name), :own)
        sv = Macro.unique_var(:hw_n, __MODULE__)

        step =
          quote do
            {unquote(bin), unquote(sv)} = EHLS.NIFRun.run(unquote(sv), unquote(bin), [unquote_splicing(defaults)])
          end

        first = quote(do: EHLS.NIFRun.init(unquote(kernel), unquote(words)))
        pos = length(ctx.svars) + 1

        # transform(.., name: n): the state's words from the front of the kernel's state binary, made the state's value
        reads =
          case stage[:state_name] do
            nil ->
              []

            n ->
              spec = Map.fetch!(states, stage.name)
              specs = flat(spec)
              ws = Macro.generate_arguments(length(specs), __MODULE__)
              {value, []} = nif_state_value(spec, Enum.zip(ws, specs))

              [quote do
                 def unquote(:"__cpu_read_#{name}__")(states, :state, unquote(n)) do
                   {_k, bin} = :erlang.element(unquote(pos), states)
                   [unquote_splicing(ws)] = EHLS.CpuInstance.words(bin, unquote(length(specs)))
                   unquote(value)
                 end
               end]
          end

        {%{ctx | steps: ctx.steps ++ binds ++ repack ++ [step], svars: ctx.svars ++ [sv], firsts: ctx.firsts ++ [first], reads: ctx.reads ++ reads}, tout}
      end)

    ctx = %{ctx | steps: ctx.steps ++ [quote(do: unquote(list) = unquote(pack).unpack(unquote(bin), unquote(Macro.escape(layout(last_out)))))],
                 exact: MapSet.put(ctx.exact, list)}
    {{:list, list, last_out}, ctx}
  end

  # the value of a state from its words (each wrapped to its type), tuples as the state's type has them
  defp nif_state_value({:tuple, specs}, ws) do
    {items, rest} = Enum.map_reduce(specs, ws, &nif_state_value/2)
    {{:{}, [], items}, rest}
  end

  defp nif_state_value({w, sg}, [{v, _} | rest]), do: {quote(do: EHLS.wrap(unquote(v), unquote(w), unquote(sg))), rest}

  defp cpu_segment_elixir(stages, fused, cpu, list, xv, out_spec, env, ctx) do
    %{name: name, not_yet: not_yet} = env

    ctx =
      Enum.zip(stages, EHLS.Pipeline.initial_states(fused))
      |> Enum.reduce(ctx, fn {stage, init}, ctx ->
        info = Map.fetch!(cpu, stage.name)
        fname = stage.name
        {binds, defaults} = cpu_binds(cpu_defaults(stage, info, not_yet))

        # an agent's function: the state the agent's first function made, one variable for all of them
        shared = stage[:agent] && Map.get(ctx.agents, stage[:agent])

        if info.state? and shared do
          st = Macro.unique_var(:hw_st, __MODULE__)

          step =
            quote do
              {unquote(list), unquote(shared)} =
                EHLS.run_cpu(fn unquote(xv), unquote(st) -> unquote(fname)(unquote(xv), unquote(st), unquote_splicing(defaults)) end, unquote(list), unquote(shared))
            end

          %{ctx | steps: ctx.steps ++ binds ++ [step]}
        else if info.state? do
          sv = Macro.unique_var(:hw_s, __MODULE__)
          st = Macro.unique_var(:hw_st, __MODULE__)
          pos = length(ctx.svars) + 1
          ctx = if stage[:agent], do: %{ctx | agents: Map.put(ctx.agents, stage[:agent], sv)}, else: ctx

          first =
            cond do
              init == nil -> quote(do: unquote(fname)(:zero))
              info[:layout] -> __tuple_init__(init, {:layout, info.layout, nil})
              info.memories? -> quote(do: :erlang.setelement(1, unquote(fname)(:zero), unquote(init)))
              true -> init
            end

          step =
            quote do
              {unquote(list), unquote(sv)} =
                EHLS.run_cpu(fn unquote(xv), unquote(st) -> unquote(fname)(unquote(xv), unquote(st), unquote_splicing(defaults)) end, unquote(list), unquote(sv))
            end

          reads =
            case stage[:state_name] do
              nil ->
                []

              n ->
                [quote do
                   def unquote(:"__cpu_read_#{name}__")(states, :state, unquote(n)) do
                     st = :erlang.element(unquote(pos), states)
                     unquote(state_part(quote(do: st), info))
                   end
                 end]
            end

          %{ctx | steps: ctx.steps ++ binds ++ [step], svars: ctx.svars ++ [sv], firsts: ctx.firsts ++ [first], reads: ctx.reads ++ reads}
        else
          step = quote(do: unquote(list) = :lists.map(fn unquote(xv) -> unquote(fname)(unquote(xv), unquote_splicing(defaults)) end, unquote(list)))
          %{ctx | steps: ctx.steps ++ binds ++ [step]}
        end
        end
      end)

    {{:list, list, out_spec}, ctx}
  end

  # An instance of levels placed on the CPU: a call computes its body (the generated defhls, as in the FPGA) and holds
  # the result, which `f(:value)` reads and a stage wired to it reads once per call. The held result is the process's
  # state (EHLS.CpuInstance), from `initial:` (0 when not given) at the start.
  defp cpu_level_instance(name, args, opts, body, caller) do
    module = inspect(caller.module)

    if name in (Module.get_attribute(caller.module, :hw_all_fns) || []),
      do: raise(ArgumentError, "definstance #{name}: a defhls of this module has that name; the name tells an instance from a function")

    fns = Module.get_attribute(caller.module, :hw_fns) || %{}
    lvl = EHLS.Level.describe!(name, args, opts, body, fns, &spec!/1)
    levels = Module.get_attribute(caller.module, :hw_levels) || %{}
    Module.put_attribute(caller.module, :hw_levels, Map.put(levels, name, Map.take(lvl, [:ret, :initial])))
    gname = :"#{name}__level"
    {gen_head, gen_body} = EHLS.Level.kernel_def(gname, lvl, &spec_ast/1)
    defined = define(gen_head, gen_body, caller)
    key = String.to_atom("#{module}.#{name}")
    vars = Macro.generate_arguments(length(lvl.args), __MODULE__)
    t = Macro.unique_var(:hw_t, __MODULE__)

    quote do
      unquote(defined)

      @doc false
      def unquote(:"__cpu_step_#{name}__")(list, held) do
        # the generated defhls takes the one argument, or the arguments as one tuple
        out = :lists.map(fn unquote(t) -> unquote(gname)(unquote(if length(lvl.args) == 1, do: quote(do: :erlang.element(1, unquote(t))), else: t)) end, list)
        {out, if(out == [], do: held, else: :lists.last(out))}
      end

      @doc false
      def unquote(:"__cpu_init_#{name}__")(), do: unquote(Macro.escape(lvl.initial))
      @doc false
      def unquote(:"__cpu_read_#{name}__")(held, :value, _), do: held
      @doc false
      def unquote(:"__cpu_source_#{name}__")(), do: nil
      @doc false
      def unquote(:"__cpu_buffer_#{name}__")(), do: 1
      @doc false
      def unquote(:"__cpu_overflow_#{name}__")(), do: :wait
      @doc false
      def unquote(:"__cpu_pack_#{name}__")(list), do: list

      def unquote(name)(:start), do: EHLS.CpuInstance.control(unquote(key), __MODULE__, unquote(name), :start)
      def unquote(name)(:stop), do: EHLS.CpuInstance.control(unquote(key), __MODULE__, unquote(name), :stop)
      # the result held now
      def unquote(name)(:value), do: EHLS.CpuInstance.read(unquote(key), __MODULE__, unquote(name), [:value, nil])
      # computes with these arguments and holds the result; gives it back (wait: false: :ok)
      def unquote(name)(unquote_splicing(vars)), do: unquote(name)(unquote_splicing(vars), [])

      def unquote(name)(unquote_splicing(vars), opts) when is_list(opts) do
        case EHLS.CpuInstance.call(unquote(key), __MODULE__, unquote(name), [{unquote_splicing(vars)}], opts) do
          {:ok, [r]} -> if EHLS.CpuInstance.opt(opts, :wait, true), do: r, else: :ok
          error -> error
        end
      end
    end
  end

  # an instance on the CPU whose stream comes from a source: what comes out, taken by f(:out, n) or f(:request, :out, n)
  defp source_calls(name, key, output?, pack, out_layout) do
    if output? do
      [quote do
         # the next n elements, waiting for them: a binary (as: :list for a list)
         def unquote(name)(:out, n) when is_integer(n), do: unquote(name)(:out, n, [])

         def unquote(name)(:out, n, opts) when is_integer(n) and n >= 0 and is_list(opts) do
           case EHLS.CpuInstance.out(unquote(key), __MODULE__, unquote(name), n, opts) do
             {:ok, out} ->
               case EHLS.CpuInstance.opt(opts, :as, :binary) do
                 :list -> out
                 :binary -> unquote(pack).pack(out, unquote(out_layout))
               end

             error ->
               error
           end
         end

         # {name, :out, binary} comes when n elements are there
         def unquote(name)(:request, :out, n) when is_integer(n) and n >= 0,
           do: EHLS.CpuInstance.request(unquote(key), __MODULE__, unquote(name), n, :out)
       end]
    else
      []
    end
  end

  # on: :cpu goes (the instance is on the CPU already); on: :fpga in an instance on the CPU is later (mixed, step 4)
  defp cpu_stages!(chain, name) do
    Macro.prewalk(chain, fn
      {f, m, args} = node when f in [:map, :transform] and is_list(args) ->
        case List.last(args) do
          opts when is_list(opts) and opts != [] ->
            if Keyword.keyword?(opts) and Keyword.has_key?(opts, :on) do
              case Keyword.get(opts, :on) do
                :cpu ->
                  rest = Keyword.delete(opts, :on)
                  {f, m, Enum.drop(args, -1) ++ if(rest == [], do: [], else: [rest])}

                other ->
                  raise ArgumentError,
                        "definstance #{name}: on: #{inspect(other)} in an instance on the CPU is not there yet (a stage in the FPGA between two on the CPU)"
              end
            else
              node
            end

          _ ->
            node
        end

      node ->
        node
    end)
  end

  defp repipe_stages([first | rest]), do: Enum.reduce(rest, first, fn st, acc -> {:|>, [], [acc, st]} end)

  defp unpipe_stages({:|>, _, [lhs, rhs]}), do: unpipe_stages(lhs) ++ [rhs]
  defp unpipe_stages(first), do: [first]

  defp stream_ref?({v, _, c}) when is_atom(v) and is_atom(c), do: true
  defp stream_ref?({:|>, _, _}), do: true
  defp stream_ref?(_), do: false

  # an instance whose arguments and result are levels (EHLS.Level): one kernel, a generated
  # defhls of its body, fired by the CPU's writes, its result held
  defp level_instance(name, args, opts, body, caller) do
    module = inspect(caller.module)

    if name in (Module.get_attribute(caller.module, :hw_all_fns) || []),
      do: raise(ArgumentError, "definstance #{name}: a defhls of this module has that name; the name tells a circuit from a function")

    fns = Module.get_attribute(caller.module, :hw_fns) || %{}
    lvl = EHLS.Level.describe!(name, args, opts, body, fns, &spec!/1)
    levels = Module.get_attribute(caller.module, :hw_levels) || %{}
    Module.put_attribute(caller.module, :hw_levels, Map.put(levels, name, Map.take(lvl, [:ret, :initial])))
    gname = :"#{name}__level"
    {gen_head, gen_body} = EHLS.Level.kernel_def(gname, lvl, &spec_ast/1)
    defined = define(gen_head, gen_body, caller)
    kernel = kernel_name(module, gname)
    key = String.to_atom("#{module}.#{name}")
    init = Enum.zip(flat_values(lvl.initial), flat(lvl.ret)) |> Enum.map(fn {v, {w, _}} -> unsigned(v, w) end)

    if dir = System.get_env("EHLS_OUT_DIR") do
      File.mkdir_p!(dir)

      pipe = %{module: module, name: name, pipeline: kernel_name(module, name), stages: [%{kernel: kernel}], links: [],
               inputs: [], output: nil, output_type: nil,
               level: %{args: Enum.map(lvl.args, &elem(&1, 0)), arg_types: Enum.map(lvl.args, &spec_name(elem(&1, 1))),
                        ret: spec_name(lvl.ret), initial: init}}

      File.write!(Path.join(dir, "#{kernel_name(module, name)}.pipeline"), JSON.encode!(pipe))
    end

    vars = Macro.generate_arguments(length(lvl.args), __MODULE__)
    in_specs = Enum.flat_map(lvl.args, &flat(elem(&1, 1)))
    out_specs = flat(lvl.ret)
    lane = if Enum.any?(in_specs ++ out_specs, &wider_than_port?/1), do: 64, else: 32
    shape = lvl.ret

    control =
      if rt = EHLS.runtime() do
        info = quote(do: {:hw_kernels.level(unquote(key)), unquote(lane), unquote(Macro.escape(in_specs)), unquote(Macro.escape(out_specs)), unquote(Macro.escape(shape))})
        pipe = quote(do: :hw_kernels.pipeline(unquote(key)))

        quote do
          def unquote(name)(:start), do: unquote(rt).pipe_enable(unquote(pipe), true)
          def unquote(name)(:stop), do: unquote(rt).pipe_enable(unquote(pipe), false)
          # the result held now
          def unquote(name)(:value), do: EHLS.__level_value__(unquote(rt), unquote(info))
          # writes the arguments; waits for that write's result, and gives it back
          def unquote(name)(unquote_splicing(vars)), do: unquote(name)(unquote_splicing(vars), [])

          def unquote(name)(unquote_splicing(vars), opts) when is_list(opts),
            do: EHLS.__level_call__(unquote(rt), unquote(pipe), unquote(info), [unquote_splicing(vars)], opts)
        end
      else
        no_hw = "#{inspect(caller.module)}.#{name}: an instance runs on a board, with a runtime backend (EHLS_RUNTIME); on this computer, check it with mix ehls.sim"

        for n <- Enum.uniq([1, length(vars), length(vars) + 1]) do
          quote do
            def unquote(name)(unquote_splicing(Macro.generate_arguments(n, __MODULE__))), do: raise(ArgumentError, unquote(no_hw))
          end
        end
        |> then(&{:__block__, [], &1})
      end

    quote do
      unquote(defined)
      unquote(control)
    end
  end

  # the compiler's own blocks: the join of zip_with and a fork (hls_litex.py Zip, Fork)
  @own_blocks %{hw__zip: {:block, 3, "hw__internal"}, hw__fork: {:block, 3, "hw__internal"}}

  # The instance's graph from its body (EHLS.Join.normalize'd): each pipe between joins made stages by
  # segment/6, the joins linked between them. Returns the accumulator with `out`: {:arg, name} for an
  # argument nothing has taken yet, else {stage, type, rate} of what the expression gives.
  defp build({:zip_with, m, [a, b, fun]}, ctx, acc) do
    EHLS.Error.at(m[:line], fn ->
      f =
        case fun do
          {:&, _, [{:/, _, [{f, _, _}, 2]}]} when is_atom(f) -> f
          other -> raise ArgumentError, "definstance: zip_with(a, b, &f/2), a function of two arguments, got #{Macro.to_string(other)}"
        end

      module = inspect(ctx.caller.module)
      fns = Module.get_attribute(ctx.caller.module, :hw_fns) || %{}

      info =
        case Map.fetch(fns, f) do
          {:ok, info} -> info
          :error -> raise ArgumentError, "definstance: zip_with(a, b, &#{f}/2): #{f} is no defhls of two arguments without state of #{module}"
        end

      gname = :"#{f}__zip"
      {head, kbody} = EHLS.Join.kernel_def(gname, info, &spec_ast/1)
      [{_, t1}, {_, t2}] = info.params
      acc = build(a, ctx, acc)
      out_a = acc.out
      acc = build(b, ctx, acc)
      out_b = acc.out
      defs = if gname in acc.hls_fns, do: [], else: [define(head, kbody, ctx.caller)]
      acc = %{acc | defs: acc.defs ++ defs, hls_fns: [gname | acc.hls_fns]}
      lane = if Enum.any?(flat(t1) ++ flat(t2), &wider_than_port?/1), do: 64, else: 32
      zargs = [lane, length(flat(t1)), length(flat(t2))]
      zm = Keyword.take(m, [:line])
      chain = {:|>, [], [{:hw__zip, zm, zargs}, {:map, zm, [{:&, [], [{:/, [], [{gname, [], nil}, 1]}]}]}]}

      extra = %{blocks: %{hw__zip: {:block, 3, "hw__internal"}}, types: %{hw__zip: {t1, {:tuple, [t1, t2]}}}}
      seg = segment(chain, true, ctx.caller, acc.hls_fns, ctx.packages, extra)
      at = length(acc.stages)
      stages = List.update_at(seg.stages, 0, &Map.put(&1, :fields, fields(t1) ++ fields(t2)))
      acc = add_segment(acc, %{seg | stages: stages}, at)
      acc = feed(acc, out_a, at, 0, t1, "#{f}'s first argument", ctx)
      acc = feed(acc, out_b, at, 1, t2, "#{f}'s second argument", ctx)
      {_, out} = List.last(seg.types)
      rate = case out_a, do: ({:arg, _} -> {1, 1}; {_, _, r} -> r)
      %{acc | out: {at + 1, out, rate}}
    end)
  end

  # A body of several statements: `v = expr` names a stream, a statement before the last ends in
  # something taking the stream away (a sink), the last is the instance's output.
  defp build({:__block__, _, stmts}, ctx, acc) do
    {init, [last]} = Enum.split(stmts, -1)

    acc =
      Enum.reduce(init, acc, fn
        {:=, m, [{v, _, c}, expr]}, acc when is_atom(v) and is_atom(c) ->
          EHLS.Error.at(m[:line], fn ->
            if MapSet.member?(ctx.streams, v), do: raise(ArgumentError, "definstance #{ctx.name}: #{v} is an argument already")
            if Map.has_key?(acc.env, v), do: raise(ArgumentError, "definstance #{ctx.name}: #{v} is bound twice")
            if Map.get(ctx.uses, v, 0) == 0, do: raise(ArgumentError, "definstance #{ctx.name}: nothing happens to #{v}")
            acc = build(expr, ctx, acc)
            if match?({:arg, _}, acc.out), do: raise(ArgumentError, "definstance #{ctx.name}: #{v} = an argument: use the argument")
            %{acc | env: Map.put(acc.env, v, acc.out)}
          end)

        {:=, m, _}, _acc ->
          EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: a stream is named by a variable, v = ..." end)

        stmt, acc ->
          acc = build(stmt, ctx, acc)
          line = if match?({_, m, _} when is_list(m), stmt), do: elem(stmt, 1)[:line]

          EHLS.Error.at(line, fn ->
            case acc.out do
              {:arg, v} ->
                raise ArgumentError, "definstance #{ctx.name}: nothing happens to #{v} here"

              {at, _, _} ->
                st = Enum.at(acc.stages, stage_at(at))

                # an instance called last: its output stays its own, read with its own calls
                if not Map.has_key?(st, :call) and EHLS.Pipeline.output?([st], Map.merge(EHLS.Blocks.table(ctx.packages), @own_blocks)),
                  do: raise(ArgumentError, "definstance #{ctx.name}: a stream nobody takes: only the last expression goes to the CPU; end this one in a sink (run(), hold(name), ...)")
            end
          end)

          acc
      end)

    build(last, ctx, acc)
  end

  defp build({v, m, c}, ctx, acc) when is_atom(v) and is_atom(c) do
    cond do
      Map.has_key?(acc.env, v) ->
        use_bound(v, m, ctx, acc)

      MapSet.member?(ctx.streams, v) ->
        if Map.get(ctx.uses, v, 0) > 1,
          do: EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: #{v} used twice: an argument goes in once; bind what it gives to fork it (y = #{v} |> f())" end)

        %{acc | out: {:arg, v}}

      true ->
        EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: #{v} is no argument of #{ctx.name} and no stream bound before" end)
    end
  end

  defp build(expr, ctx, acc) do
    case unpipe_all(expr) do
      [{:zip_with, _, _} = z | rest] ->
        acc = build(z, ctx, acc)
        if rest == [], do: acc, else: pipe_on(acc, rest, ctx)

      [{v, vm, c} | rest] when is_atom(v) and is_atom(c) and rest != [] ->
        acc = build({v, vm, c}, ctx, acc)
        pipe_on(acc, rest, ctx)

      [first | rest] = all ->
        if instance_call?(first, ctx) do
          # an instance giving a stream of its own, called here
          acc = call(first, ctx, %{acc | out: nil})
          if rest == [], do: acc, else: pipe_on(acc, rest, ctx)
        else
          source_pipe(all, ctx, acc)
        end
    end
  end

  # a source and what follows it (up to an instance called in it)
  defp source_pipe(all, ctx, acc) do
    case Enum.split_while(all, &(not instance_call?(&1, ctx))) do
      {src, []} -> source_segment(src, ctx, acc)
      {src, rest} -> pipe_on(source_segment(src, ctx, acc), rest, ctx)
    end
  end

  defp source_segment(all, ctx, acc) do
    {all, extra} = level_changes(all, ctx)

    case all do
      [first | _] ->
        # a source and what follows it
        seg = segment(EHLS.Join.repipe(all), false, ctx.caller, acc.hls_fns, ctx.packages, extra)
        seg = subscribed_type(seg, ctx)
        at = length(acc.stages)
        acc = add_segment(acc, seg, at)
        {_, out} = List.last(seg.types)
        src = if match?({s, _, _} when is_atom(s), first), do: elem(first, 0)
        %{acc | out: {at + length(seg.stages) - 1, out, seg.rate}, sources: [src | acc.sources]}
    end
  end

  # changes(k_hw(:value)) first (an instance of values, here or Other.k_hw): a source giving the new value each
  # time it changes, the compiler's block hw__changes wired to it (gen_manifest.py); its type the instance's
  # when it is of this module, else given by what takes it (gives_to)
  defp level_changes([{:changes, m, [src]} | rest] = all, ctx) do
    from =
      case src do
        {name, _, [:value]} when is_atom(name) -> {inspect(ctx.caller.module), name}
        {{:., _, [{:__aliases__, _, _} = al, name]}, _, [:value]} when is_atom(name) -> {inspect(Macro.expand(al, ctx.caller)), name}
        _ -> nil
      end

    case from do
      nil ->
        {all, nil}

      {mod, name} ->
        levels = Module.get_attribute(ctx.caller.module, :hw_levels) || %{}

        type =
          if mod == inspect(ctx.caller.module) do
            case Map.fetch(levels, name) do
              {:ok, %{ret: {w, _} = ret}} when is_integer(w) and w <= 32 -> ret
              {:ok, _} -> EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: changes(#{name}(:value)): its value is one value up to 32 bits" end)
              :error -> EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: #{name} is no instance of values of #{mod}" end)
            end
          end

        stage = {:hw__changes, Keyword.put(m, :ehls_from, "#{mod}.#{name}"), []}
        extra = %{blocks: %{hw__changes: {:source, 0, "hw__internal"}}, types: %{hw__changes: {nil, type}}}
        {[stage | rest], extra}
    end
  end

  defp level_changes(all, _ctx), do: {all, nil}

  # subscribe(topic) first: the events' type is the topic's, known when the circuits are put together, so
  # what takes them says its type (gives_to) for gen_manifest.py to check; something must take them
  defp subscribed_type(%{stages: [%{block: b} = st | rest]} = seg, ctx) when b in ["subscribe", "hw__changes"] do
    _ = ctx

    case {rest, seg.types} do
      # alone (bound to a name, used later): what takes it says the type there (feed/7)
      {[], _} ->
        seg

      {[next | _], [_, {in_, _} | _]} ->
        type = Map.get(next, :declared_in, in_)
        gives = if type in [nil, :any], do: %{}, else: %{gives_to: type_name(type)}
        %{seg | stages: [Map.merge(st, gives) | rest]}
    end
  end

  defp subscribed_type(seg, _ctx), do: seg

  # Another instance of streams called in this one: `x |> fir_hw()`, `Other.fir_hw()`. The instance exists
  # once: the stream before goes into its input and its output comes out here, so neither is the
  # CPU's. Resolved when the circuits are put together (gen_manifest.py), as its types are its own.
  defp instance_call?({f, m, args}, ctx) when is_atom(f) and args in [[], nil] do
    if f == ctx.name, do: EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance #{ctx.name}: it calls itself: a loop of streams" end)
    Enum.member?(Module.get_attribute(ctx.caller.module, :hw_stream_instances) || [], f)
  end

  defp instance_call?({{:., _, [{:__aliases__, _, _}, f]}, _, []}, _ctx) when is_atom(f), do: true
  defp instance_call?(_, _), do: false

  defp call(stage, ctx, acc) do
    {target, f, m} =
      case stage do
        {{:., _, [{:__aliases__, _, _} = alias_, f]}, m, []} -> {"#{inspect(Macro.expand(alias_, ctx.caller))}.#{f}", f, m}
        {f, m, _} -> {"#{inspect(ctx.caller.module)}.#{f}", f, m}
      end

    with {:arg, v} <- acc.out do
      EHLS.Error.at(m[:line], fn ->
        raise ArgumentError,
              "definstance #{ctx.name}: #{v} goes straight into #{f}, an instance: put a function before it, or call #{f} from the CPU"
      end)
    end

    at = length(acc.stages)
    acc = %{acc | stages: acc.stages ++ [%{call: target, name: f, line: m[:line]}]}
    acc = if acc.out, do: feed(acc, acc.out, at, 0, nil, "#{f}", ctx), else: acc
    # what it gives is not known here: the next function takes it, gen_manifest.py checks the types
    %{acc | out: {at, nil, nil}}
  end

  # A bound stream: as it is when used once; used n times, a fork of n outputs after it, the next one
  # each time (the fork moves on once every branch took the element: no buffer)
  defp use_bound(v, _m, ctx, acc) do
    {from, type, rate} = Map.fetch!(acc.env, v)
    n = Map.fetch!(ctx.uses, v)

    if n > 1 and type == nil,
      do: raise(ArgumentError, "definstance #{ctx.name}: #{v}'s type is known only when the circuits are put together, so it cannot be used twice yet: put a function after it")

    if n == 1 do
      %{acc | out: {from, type, rate}}
    else
      {at, acc} =
        case Map.fetch(acc.forks, v) do
          {:ok, {at, _}} ->
            {at, acc}

          :error ->
            at = length(acc.stages)
            lane = if Enum.any?(flat(type), &wider_than_port?/1), do: 64, else: 32
            fork = %{block: "hw__fork", args: [lane, length(flat(type)), n], gateware: "hw__internal", name: :hw__fork, fields: fields(type)}
            acc = %{acc | stages: acc.stages ++ [fork]}
            acc = feed(acc, {from, type, rate}, at, 0, type, "a fork", ctx)
            {at, %{acc | forks: Map.put(acc.forks, v, {at, 0})}}
        end

      {^at, port} = Map.fetch!(acc.forks, v)
      %{acc | out: {{at, port}, type, rate}, forks: Map.put(acc.forks, v, {at, port + 1})}
    end
  end

  # a stage, or a fork's output {stage, output}
  defp stage_at({at, _port}), do: at
  defp stage_at(at), do: at

  # the stages after what acc.out gives, fed by it (an instance called among them: a wire to it)
  defp pipe_on(acc, rest, ctx) do
    case Enum.split_while(rest, &(not instance_call?(&1, ctx))) do
      {[], [c | after_]} -> acc |> then(&call(c, ctx, &1)) |> then(&if(after_ == [], do: &1, else: pipe_on(&1, after_, ctx)))
      {before, []} -> pipe_segment(acc, before, ctx)
      {before, after_} -> acc |> pipe_segment(before, ctx) |> pipe_on(after_, ctx)
    end
  end

  defp pipe_segment(acc, rest, ctx) do
    seg = segment(EHLS.Join.repipe(rest), true, ctx.caller, acc.hls_fns, ctx.packages, nil)
    at = length(acc.stages)
    acc = add_segment(acc, seg, at)
    {in_, _} = hd(seg.types)
    {_, out} = List.last(seg.types)
    first = hd(seg.stages)
    acc = feed(acc, acc.out, at, 0, Map.get(first, :declared_in, in_), "#{first.name}'s argument", ctx)
    rate = case acc.out, do: ({:arg, _} -> seg.rate; {_, _, r} -> times(r, seg.rate))
    %{acc | out: {at + length(seg.stages) - 1, out, rate}}
  end

  defp times(nil, _), do: nil
  defp times(_, nil), do: nil
  defp times({a, b}, {c, d}), do: {a * c, b * d}

  # a segment's stages at `at`, its own links
  defp add_segment(acc, seg, at) do
    inner = for l <- EHLS.Pipeline.links(seg.stages, seg.types), do: %{l | from: l.from + at, to: l.to + at}
    %{acc | stages: acc.stages ++ seg.stages, links: acc.links ++ inner, defs: acc.defs ++ seg.defs, hls_fns: acc.hls_fns ++ seg.names}
  end

  # what `out` gives into input `port` of stage `at`, which takes `type`: an argument becomes a CPU input
  defp feed(acc, {:arg, v}, at, port, type, _what, _ctx),
    do: %{acc | inputs: acc.inputs ++ [%{name: v, type: type, to: at, port: port}]}

  defp feed(acc, {from, out, _rate}, at, port, type, what, ctx) do
    # from an instance called here, or events whose type is the topic's: what the next function takes, for
    # gen_manifest.py to check
    producer = Enum.at(acc.stages, stage_at(from))

    acc =
      if out == nil and (Map.has_key?(producer, :call) or producer[:block] in ["subscribe", "hw__changes"]) and type not in [nil, :any],
        do: %{acc | stages: List.update_at(acc.stages, stage_at(from), &Map.put(&1, :gives_to, type_name(type)))},
        else: acc

    unless type in [:any, nil] or out == nil or EHLS.Pipeline.widens?(out, type) do
      producer = Enum.at(acc.stages, stage_at(from)).name

      raise ArgumentError,
            "definstance #{ctx.name}: #{producer} gives #{type_text(out)} and #{what} is #{type_text(type)}, which would change the value: write what you mean as a function, map(&f/1)"
    end

    link = %{from: stage_at(from), to: at, port: port, kind: :stream, type: type_name(out)}
    link = if is_tuple(from), do: Map.put(link, :from_port, elem(from, 1)), else: link
    %{acc | links: acc.links ++ [link]}
  end

  defp unpipe_all({:|>, _, [lhs, rhs]}), do: unpipe_all(lhs) ++ [rhs]
  defp unpipe_all(e), do: [e]

  # One pipe of an instance as its stages: stream functions expanded, functions placed with levels and
  # windows made kernels (defined here), each stage's types checked. `extra`: the compiler's own blocks
  # (the join), %{blocks, types}.
  defp segment(chain, input?, caller, hls_fns, packages, extra) do
    attr = fn k -> Module.get_attribute(caller.module, k) end
    windows = attr.(:hw_windows) || %{}
    chain = EHLS.Pipeline.expand(chain, attr.(:hw_stream_fns) || %{})
    {chain, filtered} = EHLS.Pipeline.filters(chain, attr.(:hw_fns) || %{}, &spec_ast/1)
    filter_kernels = for {gname, head, body} <- filtered, gname not in hls_fns, do: define(head, body, caller)
    hls_fns = hls_fns ++ Enum.map(filtered, &elem(&1, 0))

    {chain, at_levels} =
      EHLS.Level.place(chain, attr.(:hw_fns) || %{}, attr.(:hw_levels) || %{}, inspect(caller.module), &spec_ast/1, %{},
                       attr.(:hw_kernel_levels) || %{})

    level_kernels = for {gname, head, body} <- at_levels, gname not in hls_fns, do: define(head, body, caller)
    placed = Enum.map(at_levels, &elem(&1, 0))
    blocks = Map.merge(EHLS.Blocks.table(packages), (extra && extra.blocks) || %{})
    # the rates of the kernels just defined too; a join keeps its first input's
    rates = Map.merge(attr.(:hw_rates) || %{}, if(extra, do: %{hw__zip: {1, 1}}, else: %{}))
    rate = EHLS.Pipeline.rate(chain, rates, windows, blocks)
    {fused, generated, gen_names} = EHLS.Pipeline.fuse(chain, windows)
    wk = window_kernels(generated, caller)
    # a generated window kernel is a stage as it is, its state belongs to the window
    states = Map.drop(attr.(:hw_states) || %{}, gen_names)
    stages = EHLS.Pipeline.stages(fused, caller.module, hls_fns ++ placed ++ gen_names, states, blocks, input?)
    block_types = Map.merge(EHLS.Blocks.types(packages), (extra && extra.types) || %{})
    types = EHLS.Pipeline.types!(stages, attr.(:hw_types) || %{}, block_types)
    %{chain: chain, stages: stages, types: types, rate: rate, defs: filter_kernels ++ level_kernels ++ wk,
      names: Enum.map(filtered, &elem(&1, 0)) ++ placed ++ gen_names, blocks: blocks}
  end

  defp type_text(t), do: t |> type_name() |> name_text()
  defp name_text(l) when is_list(l), do: "{" <> Enum.map_join(l, ", ", &name_text/1) <> "}"
  defp name_text(t), do: t

  # [[bits, signed]] of a type's values, in order
  defp fields(spec), do: for({w, s} <- flat(spec), do: [w, s])

  defp stream_instance(name, args, opts, chain, caller) do
    module = inspect(caller.module)
    hls_fns = Module.get_attribute(caller.module, :hw_defhls) || []

    if name in (Module.get_attribute(caller.module, :hw_all_fns) || []),
      do: raise(ArgumentError, "definstance #{name}: a defhls of this module has that name; the name tells a circuit from a function")

    packages = Module.get_attribute(caller.module, :hw_blocks) || []
    streams = for {v, _, c} <- args, is_atom(v) and is_atom(c), into: MapSet.new(), do: v
    if :out in streams, do: raise(ArgumentError, "definstance #{name}: an argument cannot be called out, the name of the result")

    for a <- args, not match?({v, _, c} when is_atom(v) and is_atom(c), a),
        do: raise(ArgumentError, "definstance #{name}: an argument is a name")

    # every join explicit, zip_with(a, b, &f/2), its operands pipes or arguments (EHLS.Join)
    body =
      case chain do
        {:__block__, m, stmts} ->
          # a name bound to a stream is a stream too, where it is used
          named = for {:=, _, [{v, _, c}, _]} <- stmts, is_atom(v) and is_atom(c), into: streams, do: v

          normalized =
            for st <- stmts do
              case st do
                {:=, sm, [v, e]} -> {:=, sm, [v, EHLS.Join.normalize(e, named)]}
                e -> EHLS.Join.normalize(e, named)
              end
            end

          {:__block__, m, normalized}

        _ ->
          EHLS.Join.normalize(chain, streams)
      end

    # how often each name is used (a bound one used twice is a fork)
    uses =
      body
      |> Macro.prewalk(%{}, fn
        {:=, _, [{_, _, c}, e]}, acc when is_atom(c) -> {{:__ehls_bound__, [], [e]}, acc}
        {v, _, c} = n, acc when is_atom(v) and is_atom(c) -> {n, Map.update(acc, v, 1, &(&1 + 1))}
        n, acc -> {n, acc}
      end)
      |> elem(1)

    ctx = %{name: name, caller: caller, packages: packages, streams: streams, uses: uses}
    g = build(body, ctx, %{stages: [], links: [], inputs: [], defs: [], hls_fns: hls_fns, sources: [], out: nil, env: %{}, forks: %{}})

    {out_at, out_port, out_type, rate} =
      case g.out do
        {:arg, v} -> raise ArgumentError, "definstance #{name}: nothing happens to #{v}"
        {{at, port}, type, rate} -> {at, port, type, rate}
        {at, type, rate} -> {at, nil, type, rate}
      end

    last = Enum.at(g.stages, out_at)

    if out_type == nil and last[:block] in ["subscribe", "hw__changes"],
      do: raise(ArgumentError, "definstance #{name}: it ends in #{last.name}, whose type is known only when the circuits are put together: a function after it")

    if Map.has_key?(last, :call),
      do: raise(ArgumentError, "definstance #{name}: it ends in #{Enum.at(g.stages, out_at).name}, an instance: its output is that instance's; end in a function after it, or read it from that instance")

    names = Enum.map(g.inputs, & &1.name)

    for n <- names -- Enum.uniq(names),
        do: raise(ArgumentError, "definstance #{name}: #{n} goes in twice: one stream used twice is a fork, not there yet")

    for {v, _, c} <- args, is_atom(c), v not in names,
        do: raise(ArgumentError, "definstance #{name}: nothing happens to #{v}")

    blocks = Map.merge(EHLS.Blocks.table(packages), @own_blocks)
    output? = EHLS.Pipeline.output?(Enum.slice(g.stages, 0..out_at), blocks)
    cannot_wait? = Enum.any?(g.sources, &(not EHLS.Blocks.waits?(packages, &1)))
    output = EHLS.Pipeline.options!(name, opts, output?, cannot_wait?)
    tables = Module.get_attribute(caller.module, :hw_block_tables) || %{}
    EHLS.Blocks.check_stages!(g.stages, packages, tables)
    stages = EHLS.Blocks.stage_tables(g.stages, packages, tables)
    links = g.links
    inputs = g.inputs
    level_kernels = g.defs
    window_kernels = []
    key = String.to_atom("#{module}.#{name}")

    if dir = System.get_env("EHLS_OUT_DIR") do
      File.mkdir_p!(dir)
      pipe = %{module: module, name: name, pipeline: kernel_name(module, name), stages: Enum.map(stages, &Map.drop(&1, [:line, :name, :declared_in, :declared_out])),
              links: links, inputs: Enum.map(inputs, &%{&1 | type: type_name(&1.type)}), output: output, output_from: out_at, output_port: out_port,
              output_type: output && type_name(out_type)}
      File.write!(Path.join(dir, "#{kernel_name(module, name)}.pipeline"), JSON.encode!(pipe))
    end

    # the hardware control, with a runtime backend (without one, calls that raise)
    control =
      if rt = EHLS.runtime() do
        pipe = quote(do: :hw_kernels.pipeline(unquote(key)))
        end_of = fn n -> quote(do: :hw_kernels.cpu_end(unquote(key), unquote(n))) end
        # one input: the calls as before; two (a join): f(a, b), f(a, b, opts), :send per input
        input = if length(inputs) == 1, do: hd(inputs).name
        ein = end_of.(input)
        eout = end_of.(:out)
        # the CPU ends it has in the build: an input or output wired to another instance has none
        to_cancel = quote(do: :hw_kernels.cpu_ends(unquote(key)))
        {num, den} = rate || {0, 0}
        in_type = if inputs != [], do: hd(inputs).type
        in_size = packed_size(in_type)
        out_size = packed_size(out_type)
        in_layout = layout(in_type)
        out_layout = layout(out_type)
        many = if length(inputs) > 1, do: inputs, else: []
        datas = Macro.generate_arguments(length(many), __MODULE__)

        many_calls =
          if many == [] do
            []
          else
            ins =
              for {inp, d} <- Enum.zip(many, datas) do
                quote do
                  {unquote(end_of.(inp.name)), unquote(inp.name), EHLS.__packed__(unquote(rt), unquote(d), unquote(Macro.escape(layout(inp.type)))),
                   unquote(packed_size(inp.type))}
                end
              end

            guard = Enum.reduce(datas, true, fn d, acc -> quote(do: unquote(acc) and (is_binary(unquote(d)) or is_list(unquote(d)))) end)
            first = hd(datas)

            [quote do
               # the inputs together, as many elements each (a join takes one of each); the output as
               # f(data) gives it
               def unquote(name)(unquote_splicing(datas)) when unquote(guard), do: unquote(name)(unquote_splicing(datas), [])

               def unquote(name)(unquote_splicing(datas), opts) when unquote(guard) and is_list(opts) do
                 ins = [unquote_splicing(ins)]
                 {_, _, bin, size} = hd(ins)
                 n = unquote(if output, do: quote(do: EHLS.__out_size__(bin, opts, unquote(num), unquote(den), size)), else: 0)
                 out = EHLS.__all__(unquote(rt), unquote(pipe), ins, unquote(if output, do: eout, else: nil), unquote(name), n, unquote(out_size), opts)
                 unquote(if output, do: quote(do: EHLS.__as__(unquote(rt), out, opts, is_list(unquote(first)), unquote(Macro.escape(out_layout)))), else: quote(do: out))
               end
             end] ++
              for inp <- many do
                quote do
                  # {name, input, :sent}, once the DMA has read it
                  def unquote(name)(:send, unquote(inp.name), data) when is_binary(data) or is_list(data),
                    do: EHLS.__send__(unquote(rt), unquote(pipe), unquote(end_of.(inp.name)), unquote(name), unquote(inp.name),
                                      EHLS.__packed__(unquote(rt), data, unquote(Macro.escape(layout(inp.type)))), unquote(packed_size(inp.type)))

                  def unquote(name)(:send, unquote(inp.name), value) when is_integer(value) or is_tuple(value),
                    do: EHLS.__push__(unquote(rt), unquote(pipe), unquote(end_of.(inp.name)), value, unquote(Macro.escape(layout(inp.type))))
                end
              end
          end

        quote do
          unquote_splicing(many_calls)

          def unquote(name)(:start), do: unquote(rt).pipe_enable(unquote(pipe), true)

          # what is in flight is cancelled; what the links and the buffer hold is dropped
          def unquote(name)(:stop) do
            for e <- unquote(to_cancel), do: unquote(rt).end_cancel(e)
            unquote(rt).pipe_enable(unquote(pipe), false)
          end

          unquote_splicing(
            if input do
              [quote do
                 def unquote(name)(data) when is_binary(data) or is_list(data), do: unquote(name)(data, [])
               end]
            else
              []
            end
          )

          # the latest word that reached a hold(name) stage
          def unquote(name)(:value, hold) when is_atom(hold) do
            {base, types} = :hw_kernels.hold(unquote(key), hold)
            EHLS.__state__(unquote(rt), base, types)
          end

          # the current state of the stage transform(init, &g/2, name: f), as g's state value
          def unquote(name)(:state, f) when is_atom(f) do
            case :hw_kernels.state(unquote(key), f) do
              {base, types} -> EHLS.__state__(unquote(rt), base, types)
              # a state holding memories: its values and each memory read in turn
              {base, types, parts} -> EHLS.__state__(unquote(rt), base, types, parts)
            end
          end

          # an agent's state, as Agent.get: only of an agent with a name (the circuit to read it is made for those)
          unquote(agent_gets(name, caller))

          unquote_splicing(
            cond do
              input && output ->
                [quote do
                   # a list in, a list out; a binary in, a binary out; `as:` says otherwise
                   def unquote(name)(data, opts) when (is_binary(data) or is_list(data)) and is_list(opts) do
                     bin = EHLS.__packed__(unquote(rt), data, unquote(in_layout))
                     n = EHLS.__out_size__(bin, opts, unquote(num), unquote(den), unquote(in_size))
                     out = EHLS.__both__(unquote(rt), unquote(pipe), unquote(ein), unquote(eout), unquote(name), unquote(input), bin, unquote(in_size), n, unquote(out_size), opts)
                     EHLS.__as__(unquote(rt), out, opts, is_list(data), unquote(out_layout))
                   end
                 end]

              input ->
                [quote do
                   def unquote(name)(data, opts) when (is_binary(data) or is_list(data)) and is_list(opts),
                     do: EHLS.__in__(unquote(rt), unquote(pipe), unquote(ein), unquote(name), unquote(input), EHLS.__packed__(unquote(rt), data, unquote(in_layout)), unquote(in_size), opts)
                 end]

              true ->
                []
            end
          )

          unquote_splicing(
            if input do
              [quote do
                 def unquote(name)(:in, data) when is_binary(data) or is_list(data), do: unquote(name)(:in, data, [])
               end]
            else
              []
            end
          )

          unquote_splicing(
            if output do
              [quote do
                 def unquote(name)(:out, n) when is_integer(n), do: unquote(name)(:out, n, [])
               end]
            else
              []
            end
          )

          unquote_splicing(
            if input do
              [quote do
                 def unquote(name)(:in, data, opts) when (is_binary(data) or is_list(data)) and is_list(opts),
                   do: EHLS.__in__(unquote(rt), unquote(pipe), unquote(ein), unquote(name), unquote(input), EHLS.__packed__(unquote(rt), data, unquote(in_layout)), unquote(in_size), opts)

                 # {name, input, :sent}, once the DMA has read it
                 def unquote(name)(:send, unquote(input), data) when is_binary(data) or is_list(data),
                   do: EHLS.__send__(unquote(rt), unquote(pipe), unquote(ein), unquote(name), unquote(input), EHLS.__packed__(unquote(rt), data, unquote(in_layout)), unquote(in_size))

                 # one element, without DMA: :ok once it is in the input's FIFO, {:error, :full} without room
                 def unquote(name)(:send, unquote(input), value) when is_integer(value) or is_tuple(value),
                   do: EHLS.__push__(unquote(rt), unquote(pipe), unquote(ein), value, unquote(Macro.escape(in_layout)))
               end]
            else
              []
            end
          )

          unquote_splicing(
            if output do
              [quote do
                 # a binary, or a list with `as: :list`
                 def unquote(name)(:out, n, opts) when is_integer(n) and is_list(opts) do
                   out = EHLS.__out__(unquote(rt), unquote(pipe), unquote(eout), unquote(name), n, unquote(out_size), opts)
                   EHLS.__as__(unquote(rt), out, opts, false, unquote(out_layout))
                 end

                 # {name, :out, binary}, once n elements have arrived
                 def unquote(name)(:request, :out, n) when is_integer(n),
                   do: EHLS.__request__(unquote(rt), unquote(pipe), unquote(eout), unquote(name), n, unquote(out_size))
               end]
            else
              []
            end
          )
        end
      else
        # without a runtime backend (on a computer) the calls exist, so that a module calling its
        # instance compiles anywhere, and they say where the instance runs
        no_hw = "#{inspect(caller.module)}.#{name}: an instance runs on a board, with a runtime backend (EHLS_RUNTIME); on this computer, check it with mix ehls.sim"

        for n <- Enum.uniq([1, 2, 3, length(inputs), length(inputs) + 1]) do
          quote do
            def unquote(name)(unquote_splicing(Macro.generate_arguments(n, __MODULE__))), do: raise(ArgumentError, unquote(no_hw))
          end
        end
        |> then(&{:__block__, [], &1})
      end

    quote do
      unquote_splicing(level_kernels)
      unquote_splicing(window_kernels)
      unquote(control)
    end
  end


  defp stream_head?({:"::", _, [{_, _, params}, _]}) when is_list(params),
    do: Enum.any?(params, &match?({:"::", _, [_, {:stream, _, _}]}, &1))

  defp stream_head?({:when, _, [h, _]}), do: stream_head?(h)
  defp stream_head?(_), do: false

  # A function of a stream: a chain of stages with a name. In an instance its stages are expanded in place
  # (EHLS.Pipeline.expand/2); on the CPU, a function from a list to a list, from the initial state.
  defp stream_fn({:"::", _, [{name, _, [{:"::", _, [{x, _, ctx} = var, {:stream, _, [in_type]}]} | level_args]}, {:stream, _, [out_type]}]}, body, caller)
       when is_atom(x) and is_atom(ctx) do
    # levels after the stream: plain arguments with a type, given where the function is placed
    level_args =
      for a <- level_args do
        case a do
          {:"::", _, [{k, _, kc} = kvar, t]} when is_atom(k) and is_atom(kc) ->
            spec = spec!(t)
            unless match?({w, _} when is_integer(w) and w <= 32, spec),
              do: raise(ArgumentError, "defhls #{name}: a level argument #{k} is one value up to 32 bits")
            {k, kvar, spec}

          _ ->
            raise ArgumentError, "defhls #{name}: after the stream come levels, arguments with a type (k :: u9)"
        end
      end

    in_spec = spec!(in_type)
    out_spec = spec!(out_type)
    packages = Module.get_attribute(caller.module, :hw_blocks) || []
    blocks = EHLS.Blocks.table(packages)
    windows = Module.get_attribute(caller.module, :hw_windows) || %{}
    known = Module.get_attribute(caller.module, :hw_stream_fns) || %{}
    chain = body |> EHLS.Pipeline.normalize() |> EHLS.Pipeline.stream_body!(name, x) |> EHLS.Pipeline.expand(known)
    {chain, filtered} = EHLS.Pipeline.filters(chain, Module.get_attribute(caller.module, :hw_fns) || %{}, &spec_ast/1)
    known_fns = Module.get_attribute(caller.module, :hw_defhls) || []
    filter_kernels = for {gname, head, kbody} <- filtered, gname not in known_fns, do: define(head, kbody, caller)
    EHLS.Pipeline.no_blocks!(chain, name, blocks, Module.get_attribute(caller.module, :hw_all_fns) || [], windows)
    hls_fns = Module.get_attribute(caller.module, :hw_defhls) || []

    # functions of several arguments, placed with integers, levels or the level arguments (EHLS.Level.place)
    {placed_chain, at_levels} =
      EHLS.Level.place(chain, Module.get_attribute(caller.module, :hw_fns) || %{}, Module.get_attribute(caller.module, :hw_levels) || %{},
                       inspect(caller.module), &spec_ast/1, Map.new(level_args, fn {k, _, spec} -> {k, spec} end),
                       Module.get_attribute(caller.module, :hw_kernel_levels) || %{})

    level_kernels = for {gname, head, kbody} <- at_levels, gname not in hls_fns, do: define(head, kbody, caller)
    hls_fns = hls_fns ++ Enum.map(at_levels, &elem(&1, 0))
    {fused, generated, gen_names} = EHLS.Pipeline.fuse(placed_chain, windows)
    window_kernels = window_kernels(generated, caller)
    states = Map.drop(Module.get_attribute(caller.module, :hw_states) || %{}, gen_names)
    stages = EHLS.Pipeline.stages(fused, caller.module, hls_fns ++ gen_names, states, blocks, true)
    types = EHLS.Pipeline.types!(stages, Module.get_attribute(caller.module, :hw_types) || %{}, EHLS.Blocks.types(packages))
    EHLS.Pipeline.check_ends!(name, in_spec, out_spec, types)

    Module.put_attribute(caller.module, :hw_stream_fns,
      Map.put(known, name, %{chain: chain, in: in_spec, out: out_spec, levels: Enum.map(level_args, &elem(&1, 0))}))
    cpu = Module.get_attribute(caller.module, :hw_cpu) || %{}
    list = Macro.unique_var(:hw_list, __MODULE__)
    elem_var = var
    in_wrap = quote(do: :lists.map(fn unquote(elem_var) -> unquote(wrap_code(elem_var, in_spec)) end, unquote(list)))

    kvars = Map.new(level_args, fn {k, kvar, _} -> {k, kvar} end)

    steps =
      for {stage, init} <- Enum.zip(stages, EHLS.Pipeline.initial_states(fused)) do
        info = Map.fetch!(cpu, stage.name)
        # a generated kernel's arguments after the first are levels: the level arguments' values on the CPU
        info =
          case stage[:wires] do
            nil -> info
            wires ->
              args =
                for w <- wires do
                  cond do
                    Map.has_key?(w, :var) -> Map.fetch!(kvars, w.var)
                    Map.has_key?(w, :const) -> w.const
                    true ->
                      raise ArgumentError,
                            "defhls #{name}: a stream function takes its levels as arguments (k :: u9), given where it is placed (#{name}(samples, k_hw(:value)))"
                  end
                end

              %{info | args: args}
          end

        quote(do: unquote(list) = unquote(cpu_stage(stage.name, info, init, list)))
      end

    y = Macro.unique_var(:hw_y, __MODULE__)
    kwraps = for {_, kvar, spec} <- level_args, do: quote(do: unquote(kvar) = unquote(wrap_code(kvar, spec)))
    kguards = for {_, kvar, _} <- level_args, do: quote(do: is_integer(unquote(kvar)))
    guard = Enum.reduce(kguards, quote(do: is_list(unquote(list))), fn g, acc -> quote(do: unquote(acc) and unquote(g)) end)

    quote do
      unquote_splicing(filter_kernels)
      unquote_splicing(level_kernels)
      unquote_splicing(window_kernels)

      def unquote(name)(unquote(list), unquote_splicing(Enum.map(level_args, &elem(&1, 1)))) when unquote(guard) do
        unquote_splicing(kwraps)
        unquote(list) = unquote(in_wrap)
        unquote_splicing(steps)
        :lists.map(fn unquote(y) -> unquote(wrap_code(y, out_spec)) end, unquote(list))
      end
    end
  end

  # a stage over a list, on the CPU: its levels' values, a state from what the stage says
  defp cpu_stage(name, %{state?: false, args: defaults}, _init, list) do
    x = Macro.unique_var(:hw_x, __MODULE__)
    quote(do: :lists.map(fn unquote(x) -> unquote(name)(unquote(x), unquote_splicing(defaults)) end, unquote(list)))
  end

  defp cpu_stage(name, %{state?: true, args: defaults, memories?: memories?} = info, init, list) do
    x = Macro.unique_var(:hw_x, __MODULE__)
    st = Macro.unique_var(:hw_s, __MODULE__)

    first =
      cond do
        init == nil -> quote(do: unquote(name)(:zero))
        info[:layout] -> __tuple_init__(init, {:layout, info.layout, nil})
        memories? -> quote(do: :erlang.setelement(1, unquote(name)(:zero), unquote(init)))
        true -> init
      end

    quote do
      :erlang.element(1, EHLS.run_cpu(fn unquote(x), unquote(st) -> unquote(name)(unquote(x), unquote(st), unquote_splicing(defaults)) end, unquote(list), unquote(first)))
    end
  end

  # the kernels `window(n) |> every(k) |> map(&f/1)` become; two uses share the definition
  defp window_kernels(generated, caller) do
    for {:defhls, _, [{:"::", _, [{gname, _, _}, _]} = gen_head, [do: gen_body]]} <- generated,
        gname not in (Module.get_attribute(caller.module, :hw_defhls) || []) do
      define(gen_head, gen_body, caller)
    end
  end

  defp define(head, body, caller) do
    EHLS.Error.compile(caller.file, caller.line, fn ->
      if stream_head?(head), do: stream_fn(head, body, caller), else: define_word(head, body, caller)
    end)
  end

  defp define_word(head, body, caller) do
    EHLS.Error.compile(caller.file, caller.line, fn ->
      case parse_head(head) do
        {name, [{wvar, {:tuple, _, [etype, n]}, nil}], ret_type} ->
          window_fn(name, wvar, etype, n, ret_type, body, caller)

        {name, params, ret_type} ->
          # several arguments: only for calling from other defhls functions
          if Enum.all?(params, &plain_arg?/1) and length(params) > 1,
            do: helper(name, params, ret_type, body, caller),
            else: kernel(head, body, caller)
      end
    end)
  end

  defp wider_than_port?({:tuple, specs}), do: Enum.any?(specs, &wider_than_port?/1)
  defp wider_than_port?({:emit, spec}), do: wider_than_port?(spec)
  defp wider_than_port?({w, _}) when is_integer(w), do: w > @port
  defp wider_than_port?(_), do: false

  # after the first argument: a level (a plain type, or a generated kernel's hw__level), not a state or a memory
  defp level_arg?({:hw__level, _, [_]}), do: true
  defp level_arg?({t, _, [_, _]}) when t in [:memory, :tuple], do: false
  defp level_arg?({:state, _, _}), do: false
  defp level_arg?(_), do: true

  defp params({:"::", _, [{_, _, ps}, _]}), do: ps
  defp params({:when, _, [h, _]}), do: params(h)

  # what each argument after the first is, in order
  defp rest_order(ps) do
    for p <- tl(ps) do
      t =
        case p do
          {:\\, _, [{:"::", _, [_, t]}, _]} -> t
          {:"::", _, [_, t]} -> t
        end

      if level_arg?(t), do: :level, else: :other
    end
  end

  # an argument with a type and nothing else: not a state, a param or a memory
  defp plain_arg?({_var, {:memory, _, [_, _]}, nil}), do: false
  defp plain_arg?({_var, {:state, _, _}, nil}), do: false
  defp plain_arg?({_var, _type, nil}), do: true
  defp plain_arg?(_), do: false

  # A function of several arguments: a kernel takes one element, so this one is only for
  # calling from other defhls functions. CPU: a function; circuit: its body inside the caller's (EHLS.Inline).
  defp helper(name, params, ret_type, body, caller) do
    ret = ret_spec!(ret_type)
    if match?({:emit, _}, ret), do: raise(ArgumentError, "defhls #{name}: a list as the output ({[y], s} / {[], s}) goes with a state")
    specs = for {var, type, nil} <- params, do: {var, spec!(type)}
    hw = inlined(body, name, caller)

    # an output that may be missing ({[y], s} / {[], s}): emit / skip in the circuit's body
    hw =
      if match?({:tuple, [{:emit, _} | _]}, ret),
        do: listed_out(hw),
        else: hw

    register_fn(caller, name, for({{v, _, _}, s} <- specs, do: {v, s}), ret, hw)

    tab_fun = fn t -> String.to_atom("__hw_table_#{name}_#{t}") end
    {cpu_body, tables} = cpu_tables(body, tab_fun)
    # an argument written _x is not used: neither cut to its type nor checked
    used = Enum.reject(specs, fn {{v, _, _}, _} -> String.starts_with?(Atom.to_string(v), "_") end)
    wraps = for {var, spec} <- used, do: quote(do: unquote(var) = unquote(wrap_code(var, spec)))
    vars = for {var, _} <- specs, do: var

    guard =
      used
      |> Enum.map(fn {var, spec} -> if match?({:tuple, _}, spec), do: quote(do: is_tuple(unquote(var))), else: quote(do: is_integer(unquote(var))) end)
      |> Enum.reduce(true, fn g, acc -> quote(do: unquote(acc) and unquote(g)) end)

    quote do
      def unquote(name)(unquote_splicing(vars)) when unquote(guard) do
        unquote_splicing(wraps)
        unquote(wrap_code(cpu_body, ret))
      end

      unquote_splicing(table_funs(tables, tab_fun, name))
    end
  end

  # the body as the circuit sees it: the calls of other defhls functions replaced
  defp inlined(body, name, caller) do
    fns = Module.get_attribute(caller.module, :hw_fns) || %{}
    others = (Module.get_attribute(caller.module, :hw_all_fns) || []) -- Map.keys(fns)
    body |> EHLS.Syntax.lower() |> EHLS.Inline.calls(name, fns, others)
  end

  defp register_fn(caller, name, params, ret, body) do
    fns = Module.get_attribute(caller.module, :hw_fns) || %{}
    Module.put_attribute(caller.module, :hw_fns, Map.put(fns, name, EHLS.Inline.describe(params, ret, body)))
  end

  defp port_spec({:memory, _, [e, _]}), do: spec!(e)
  defp port_spec({:hw__level, _, [t]}), do: spec!(t)
  defp port_spec({:state, _, [t]}), do: spec!(t)
  defp port_spec(t), do: spec!(t)

  defp tables_of(body) do
    body
    |> Macro.prewalk([], fn
      {:table, _, [{:@, _, [{t, _, _}]}, _]} = n, acc -> {n, [t | acc]}
      n, acc -> {n, acc}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  # A function of a chunk, `defhls f(w :: tuple(t, n)) :: r`: a pure function of n stream elements, the oldest first
  # (`elem(w, i)`), as chunk_every gives them; not a kernel by itself: a pipeline turns
  # `chunk_every(n, k, :discard) |> map(&f/1)` into one (EHLS.Pipeline). Here: the CPU clause, f(w) with w a tuple of n,
  # and the definition for the pipeline (@hw_windows), its elem(w, i) as w[i].
  defp window_fn(name, {wv, _, _} = wvar, etype, n, ret_type, body, caller) do
    ret_spec = ret_spec!(ret_type)
    spec!(etype)
    unless is_integer(n) and n >= 1, do: raise(ArgumentError, "defhls #{name}: tuple(type, n), n an integer")

    body =
      Macro.prewalk(body, fn
        {:elem, _, [{^wv, _, _} = v, i]} ->
          {{:., [], [Access, :get]}, [], [v, i]}

        {{:., _, [Access, :get]}, _, [{^wv, _, _}, _]} ->
          raise ArgumentError, "defhls #{name}: #{wv} is a tuple: elem(#{wv}, i)"

        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [{^wv, _, _}, _]} ->
          raise ArgumentError, "defhls #{name}: #{wv} is a tuple: elem(#{wv}, i)"

        other ->
          other
      end)

    windows = Module.get_attribute(caller.module, :hw_windows) || %{}

    Module.put_attribute(caller.module, :hw_windows,
      Map.put(windows, name, %{var: wv, etype: etype, n: n, ret: ret_type, body: body}))

    tab_fun = fn t -> String.to_atom("__hw_table_#{name}_#{t}") end
    {cpu_body, tables} = cpu_tables(body, tab_fun)

    cpu_body =
      Macro.prewalk(cpu_body, fn
        {{:., _, [Access, :get]}, _, [{^wv, _, _}, i]} -> quote(do: :erlang.element(unquote(i) + 1, unquote(wvar)))
        other -> other
      end)

    quote do
      def unquote(name)(unquote(wvar)) when is_tuple(unquote(wvar)) and tuple_size(unquote(wvar)) == unquote(n) do
        unquote(wrap_code(cpu_body, ret_spec))
      end

      unquote_splicing(table_funs(tables, tab_fun, name))
    end
  end

  # what f(:state, n) reads of a stage's CPU state: a state holding tuples is read whole, its memories too, as the
  # circuit's is (EHLS.__state__/4); the memory of the generated kernels' ring buffers (chunk_every) is not read
  defp state_part(st, %{layout: %{}}), do: st
  defp state_part(st, %{memories?: true}), do: quote(do: :erlang.element(1, unquote(st)))
  defp state_part(st, _), do: st

  # The CPU's function of a state holding tuples: the one written, its state as written (EHLS.TupleState). The values
  # are cut to their types: the element, the levels, the output, the next state's values, and each value put_elem
  # writes, to its tuple's element type. f(:zero), and __hw_init_f__(words) the state from the circuit's state words (the
  # tuples zeros), for the simulation.
  defp tuple_cpu(name, t, arg_spec, ret_spec, lvars, lwraps, tab_fun) do
    [{:"::", _, [var, _]}, {:"::", _, [pat, stype]} | _] = t.params
    var = case var, do: ({:\\, _, [v, _]} -> v; v -> v)
    elems = for {v, et, _} <- t.layout.mems, into: %{}, do: {v, spec!(et)}
    {cpu_body, _} = cpu_tables(t.body, tab_fun)

    # the tuple each name is a version of (put_elem, or another name for one), for the element type of a put_elem
    es = case cpu_body, do: ({:__block__, _, es} -> es; e -> [e])

    bases =
      Enum.reduce(es, Map.new(elems, fn {v, _} -> {v, v} end), fn
        {:=, _, [{v, _, c}, rhs]}, acc when is_atom(c) ->
          case base_of(rhs, acc), do: (nil -> acc; b -> Map.put(acc, v, b))

        _, acc ->
          acc
      end)

    cpu_body =
      Macro.prewalk(cpu_body, fn
        {:put_elem, m, [a, i, v]} = n ->
          case base_of(a, bases) do
            nil -> n
            b -> {:put_elem, m, [a, i, wrap_code(v, Map.fetch!(elems, b))]}
          end

        n ->
          n
      end)

    in_words = length(flat(arg_spec))
    guard = if in_words > 1, do: quote(do: is_tuple(unquote(var))), else: quote(do: is_integer(unquote(var)))
    state_spec = tuple_spec(stype, t.layout.shape)
    ret_spec = if t.listed?, do: {:emit, ret_spec}, else: ret_spec
    ret_spec = with {:emit, {:emit, r}} <- ret_spec, do: {:emit, r}
    {zero, init_fn} = tuple_zero(t.layout, state_spec)

    quote do
      def unquote(name)(unquote(var), unquote(pat), unquote_splicing(lvars)) when unquote(guard) do
        unquote(var) = unquote(wrap_code(var, arg_spec))
        unquote_splicing(lwraps)
        unquote(wrap_code(cpu_body, {:tuple, [ret_spec, state_spec]}))
      end

      def unquote(name)(:zero), do: unquote(zero)

      @doc false
      def unquote(:"__hw_init_#{name}__")(words), do: unquote(init_fn).(words)

      @doc false
      # the memories of a state, [{name, tuple}]: what the circuit's memories hold (the tests read them)
      def unquote(:"__hw_mems_#{name}__")(st), do: unquote(mems_of(t.layout))
    end
  end

  # the parts of a state holding memories, for the .sig: %{mem: name} or %{val: zeros} (a tuple's zeros as a list)
  defp state_shape(%{layout: %{shape: :whole, mems: [{v, _, n}]}}), do: [%{mem: v, n: n}]

  defp state_shape(%{layout: %{shape: shape}, params: [_, {:"::", _, [_, stype]} | _]}) do
    for {p, ty} <- Enum.zip(shape, tuple_items(stype)) do
      case p do
        {:mem, v, n} -> %{mem: v, n: n}
        {:val, _} -> %{val: json_zeros(zero_value(spec!(ty)))}
      end
    end
  end

  defp json_zeros(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&json_zeros/1)
  defp json_zeros(v), do: v

  defp mems_of(%{shape: :whole, mems: [{v, _, _}]}), do: quote(do: [{unquote(v), st}])

  defp mems_of(%{shape: shape}) do
    for {{:mem, v, _}, i} <- Enum.with_index(shape, 1), do: quote(do: {unquote(v), :erlang.element(unquote(i), st)})
  end

  defp base_of({v, _, c}, bases) when is_atom(v) and is_atom(c), do: Map.get(bases, v)
  defp base_of({:put_elem, _, [a, _, _]}, bases), do: base_of(a, bases)
  defp base_of(_, _), do: nil

  # a state type with tuple(t, n): {:mem, n, spec} in it
  # the state's spec on the CPU: a memory's tuple {:mem, n, t} (put_elem cuts what it writes), the other parts cut
  # whole each step, a tuple in registers too
  defp tuple_spec(stype, :whole), do: tuple_spec(stype)
  defp tuple_spec(stype, shape), do: {:tuple, for({p, ty} <- Enum.zip(shape, tuple_items(stype)), do: (case p, do: ({:mem, _, _} -> tuple_spec(ty); _ -> spec!(ty))))}

  defp tuple_spec({:tuple, _, [t, n]}), do: {:mem, n, spec!(t)}
  defp tuple_spec({a, b}), do: tuple_spec({:{}, [], [a, b]})
  defp tuple_spec({:{}, _, ts}), do: {:tuple, Enum.map(ts, &tuple_spec/1)}
  defp tuple_spec(t), do: spec!(t)

  # the state from zeros, and from the circuit's state words (the values in order, the tuples zeros)
  defp tuple_zero(%{shape: :whole, mems: [{_, _, n}]}, _spec),
    do: {quote(do: :erlang.make_tuple(unquote(n), 0)), quote(do: fn _ -> :erlang.make_tuple(unquote(n), 0) end)}

  defp tuple_zero(%{shape: shape}, {:tuple, specs}) do
    zero = {:{}, [], for({p, s} <- Enum.zip(shape, specs), do: (case p, do: ({:mem, _, n} -> quote(do: :erlang.make_tuple(unquote(n), 0)); _ -> Macro.escape(zero_value(s)))))}
    vals = for {{:val, _}, s} <- Enum.zip(shape, specs), do: s
    mems = for {{:mem, _, n}, i} <- Enum.with_index(shape), do: {i, n}

    init =
      quote do
        fn words ->
          {vs, []} = EHLS.TupleState.fill(unquote(Macro.escape(Enum.map(vals, &zero_value/1))), words)
          EHLS.TupleState.assemble(vs, unquote(mems), unquote(length(shape)))
        end
      end

    {zero, init}
  end

  # table(@attr, i) -> a call of the table's function; also returns the tables used
  defp cpu_tables(body, tab_fun) do
    Macro.prewalk(body, [], fn
      {:table, _, [{:@, _, [{t, _, _}]}, i]}, acc -> {quote(do: unquote(tab_fun.(t))(unquote(i))), [t | acc]}
      n, acc -> {n, acc}
    end)
    |> then(fn {b, ts} -> {b, ts |> Enum.uniq() |> Enum.reverse()} end)
  end

  # one function clause per entry (immediates only, see wrap_code); the attribute is read
  # when the module body runs
  defp table_funs(tables, tab_fun, name) do
    for t <- tables do
      quote bind_quoted: [f: tab_fun.(t), values: {:@, [], [{t, [], nil}]}, t: t, name: name] do
        unless is_list(values) and values != [] and Enum.all?(values, &is_integer/1),
          do: raise(ArgumentError, "defhls #{name}: @#{t} must be a list of integers")

        for {v, i} <- Enum.with_index(values), do: defp(unquote(f)(unquote(i)), do: unquote(v))

        # other indices wrap to the table's address bits, as in hardware (0 past its end)
        len = length(values)
        mask = Bitwise.bsl(1, length(Integer.digits(max(len - 1, 1), 2))) - 1

        defp unquote(f)(i) do
          j = Bitwise.band(i, unquote(mask))
          if j < unquote(len), do: unquote(f)(j), else: 0
        end
      end
    end
  end

  defp kernel(head, body, caller) do
    {name, head_params, ret_type} = parse_head(head)
    [{var, arg_type, _} | rest] = head_params
    # the CPU reads a state in 32-bit words, a level is one value up to 32 bits, and a memory space has 32-bit words
    for {_, t, _} <- rest, t_spec = port_spec(t), wider_than_port?(t_spec) do
      raise ArgumentError, "defhls #{name}: a state, a level or a memory is up to 32 bits; the argument and the result can be up to 64"
    end
    arg_spec = spec!(arg_type)
    ret_spec = ret_spec!(ret_type)
    # the ports of the kernel: 32 bits, or 64 when its argument or result has a wider value
    lane = if wider_than_port?(arg_spec) or wider_than_port?(ret_spec), do: 64, else: 32
    {arg, _, _} = var
    module = inspect(caller.module)
    kernel = kernel_name(module, name)
    hls_fns = Module.get_attribute(caller.module, :hw_defhls) || []
    Module.put_attribute(caller.module, :hw_defhls, [name | hls_fns])

    for {{pv, _, _}, t, d} <- rest, d != nil, level_arg?(t), not match?({:hw__level, _, _}, t) do
      raise ArgumentError,
            "defhls #{name}: #{pv} has a default: a level has none, it is given where #{name} is placed, and so is a state's initial value: transform(init, &#{name}/2)"
    end

    # levels: plain arguments with a type after the state and the memories, inputs the kernel reads when
    # it takes a value, given where it is placed (EHLS.Level.place); an extra argument on the CPU. A
    # generated kernel's (`p :: hw__level(t) \\ value`) come with the value it is checked at.
    {level_args, rest} = Enum.split_with(rest, fn {_, t, _} -> level_arg?(t) end)

    if Enum.drop_while(rest_order(params(head)), &(&1 != :level)) |> Enum.any?(&(&1 != :level)),
      do: raise(ArgumentError, "defhls #{name}: the levels (plain arguments with a type) come last, after the state and the memories")

    level_args =
      for {{pv, _, _} = pvar, t, default} <- level_args do
        t = with({:hw__level, _, [inner]} <- t, do: inner)
        spec = spec!(t)
        unless match?({w, _} when is_integer(w), spec), do: raise(ArgumentError, "defhls #{name}: a level #{pv} is one value up to 32 bits")
        {pv, pvar, spec, if(default == nil, do: 0, else: init_value!(default, spec))}
      end

    Module.put_attribute(caller.module, :hw_kernel_levels,
      Map.put(Module.get_attribute(caller.module, :hw_kernel_levels) || %{}, name, for({pv, _, spec, _} <- level_args, do: {pv, spec})))

    lvars = for {_, pvar, _, _} <- level_args, do: pvar
    lwraps = for {_, pvar, spec, _} <- level_args, do: quote(do: unquote(pvar) = unquote(wrap_code(pvar, spec)))

    {state, memories} = Enum.split_with(rest, fn {_, t, _} -> not match?({:memory, _, _}, t) end)

    {state_var, state_spec, init} =
      case state do
        [] -> {nil, nil, nil}
        [{sv, {:state, _, [st]}, nil}] -> {sv, spec!(st), zero_value(spec!(st))}
        [{{sv, _, _}, _, _}] -> raise ArgumentError, "defhls #{name}: #{sv} is the state, its initial value given where #{name} is placed: transform(init, &#{name}/2)"
        _ -> raise ArgumentError, "defhls #{name}: one input, at most one state, then memories"
      end

    # memories: {name, var, size, element spec}; after a state
    memories =
      for {{mv, _, _} = mvar, {:memory, _, [etype, size]}, nil} <- memories do
        unless is_integer(size) and size > 0 and Bitwise.band(size, size - 1) == 0,
          do: raise(ArgumentError, "defhls #{name}: memory sizes are powers of two")

        {mv, mvar, size, spec!(etype)}
      end

    if memories != [] and state_var == nil, do: raise(ArgumentError, "defhls #{name}: memories need a state")

    # tables: table(@attr, i) with @attr a list of integers of the module; its value is read
    # when the module body runs (after the attribute was set), not when this macro expands
    tables = tables_of(body)
    hw = inlined(body, name, caller)
    # a function of one word without state can be called from other defhls functions too
    if state_var == nil and memories == [] and level_args == [] and not match?({:emit, _}, ret_spec),
      do: register_fn(caller, name, [{arg, arg_spec}], ret_spec, hw)

    hw_tables = tables_of(hw)

    tables_ast = for t <- hw_tables, do: {t, {:@, [], [{t, [], nil}]}}

    emit = match?({:emit, _}, ret_spec)

    # a tuple input / output: several values of one stream element
    in_words = length(flat(arg_spec))
    out_words = length(flat(with({:emit, r} <- ret_spec, do: r)))
    guard = if in_words > 1, do: quote(do: is_tuple(unquote(var))), else: quote(do: is_integer(unquote(var)))
    if emit and state_var == nil, do: raise(ArgumentError, "defhls #{name}: a list as the output ({[y], s} / {[], s}) goes with a state")
    rates = Module.get_attribute(caller.module, :hw_rates) || %{}
    Module.put_attribute(caller.module, :hw_rates, Map.put(rates, name, if(emit, do: nil, else: {1, 1})))
    cpu = Module.get_attribute(caller.module, :hw_cpu) || %{}
    # a state holding tuples (EHLS.TupleState): the CPU's function is the one written, its state as written
    tuple = (Module.get_attribute(caller.module, :hw_tuple_states) || %{})[name]
    layout = tuple && tuple.layout

    Module.put_attribute(caller.module, :hw_cpu, Map.put(cpu, name, %{state?: state_var != nil, memories?: memories != [] and layout == nil,
      layout: layout, args: for({_, _, _, d} <- level_args, do: d)}))
    fn_types = Module.get_attribute(caller.module, :hw_types) || %{}
    out_spec = with({:emit, r} <- ret_spec, do: r)
    Module.put_attribute(caller.module, :hw_types, Map.put(fn_types, name, {arg_spec, out_spec}))

    if state_var do
      states = Module.get_attribute(caller.module, :hw_states) || %{}
      spec = if layout, do: {:layout, layout, state_spec}, else: state_spec
      Module.put_attribute(caller.module, :hw_states, Map.put(states, name, spec))
    end

    # the CPU clauses: an output that may be missing is a list of at most one, as written ([v] / []), a memory is a
    # tuple, a table a function
    mem_size = Map.new(memories, fn {mv, _, size, spec} -> {mv, {size, spec}} end)
    tab_fun = fn t -> String.to_atom("__hw_table_#{name}_#{t}") end

    cpu_body =
      Macro.prewalk(body, fn
        {:emit, _, [v]} ->
          [v]

        {:skip, _, []} ->
          []

        # read / write: a memory's word, the index cut to its size (the generated kernels' ring buffers)
        {:read, _, [{mv, _, _} = m, i]} ->
          {size, _} = Map.fetch!(mem_size, mv)
          quote do: :erlang.element(Bitwise.band(unquote(i), unquote(size - 1)) + 1, unquote(m))

        {:write, _, [{mv, _, _} = m, i, v]} ->
          {size, {w, s}} = Map.fetch!(mem_size, mv)
          quote do: :erlang.setelement(Bitwise.band(unquote(i), unquote(size - 1)) + 1, unquote(m), EHLS.wrap(unquote(v), unquote(w), unquote(s)))

        {:table, _, [{:@, _, [{t, _, _}]}, i]} ->
          quote do: unquote(tab_fun.(t))(unquote(i))

        other ->
          other
      end)

    table_funs = table_funs(tables, tab_fun, name)

    write_hw =
      if dir = System.get_env("EHLS_OUT_DIR") do
        mem_params = for {mv, _, size, spec} <- memories, do: {mv, {:memory, size, spec}}
        l_params = for {pv, _, spec, _} <- level_args, do: {pv, spec}

        # a pure function with tables (a memory space) or tuples runs in the hardware as a
        # a function with a 1-bit state that stays 0: the stream adapter wires the memory
        # space and takes / gives the values of an element
        pure = state_var == nil and (hw_tables != [] or in_words > 1 or out_words > 1)

        {params_mlir, result_spec, hw_body} =
          cond do
            state_var ->
              {[{arg, arg_spec}, {elem(state_var, 0), state_spec}] ++ l_params ++ mem_params,
               {:tuple, [ret_spec, state_spec]}, hw}

            pure ->
              {[{arg, arg_spec}, {:hw__pure, {1, false}}] ++ l_params, {:tuple, [ret_spec, {1, false}]}, {hw, 0}}

            true ->
              {[{arg, arg_spec}] ++ l_params, ret_spec, hw}
          end

        sig = %{
          module: module,
          function: name,
          kernel: kernel,
          arg: spec_name(arg_spec),
          ret: spec_name(ret_spec),
          emit: emit,
          state: cond(do: (state_var -> Enum.map(flat(state_spec), &spec_name/1); pure -> ["u1"]; true -> [])),
          init: cond(do: (state_var -> Enum.map(flat_values(init), &unsigned(&1, 32)); pure -> [0]; true -> [])),
          pure: pure,
          in_words: in_words,
          out_words: out_words,
          lane: lane,
          args: for({pv, _, spec, d} <- level_args, do: %{name: pv, type: spec_name(spec), kind: "level", default: d}),
          memories: for({mv, _, size, spec} <- memories, do: %{name: mv, size: size, elem: spec_name(spec)})
        }

        # a state holding memories (EHLS.TupleState): its parts in order, a value's zeros (its words' shape) or a memory
        sig = if tuple, do: Map.put(sig, :shape, state_shape(tuple)), else: sig

        quote do
          EHLS.__write_kernel__(
            unquote(caller.file),
            unquote(caller.line),
            unquote(dir),
            unquote(Macro.escape(sig)),
            unquote(Macro.escape(params_mlir)),
            unquote(Macro.escape(result_spec)),
            unquote(Macro.escape(hw_body)),
            unquote(tables_ast)
          )
        end
      end

    cond do
      tuple ->
        quote do
          unquote(write_hw)
          unquote(tuple_cpu(name, tuple, arg_spec, ret_spec, lvars, lwraps, tab_fun))
          unquote_splicing(table_funs)
        end

      memories != [] ->
        # CPU: one step with the state and the memories (tuples), {output, {state, memory..}};
        # FPGA: in pipelines
        mvars = for {_, mvar, _, _} <- memories, do: mvar
        sizes = for {_, _, size, _} <- memories, do: size
        {stmts, last} = split_body(cpu_body)

        quote do
          unquote(write_hw)

          def unquote(name)(unquote(var), {unquote(state_var), unquote_splicing(mvars)}, unquote_splicing(lvars)) when unquote(guard) do
            unquote(var) = unquote(wrap_code(var, arg_spec))
            unquote_splicing(lwraps)
            unquote(state_var) = unquote(wrap_code(state_var, state_spec))
            unquote_splicing(stmts)
            {hw_out, hw_state} = unquote(wrap_code(last, {:tuple, [ret_spec, state_spec]}))
            {hw_out, {hw_state, unquote_splicing(mvars)}}
          end

          def unquote(name)(:zero),
            do: {unquote(Macro.escape(init)), unquote_splicing(for n <- sizes, do: quote(do: :erlang.make_tuple(unquote(n), 0)))}

          unquote_splicing(table_funs)
        end

      state_var ->
        quote do
          unquote(write_hw)

          # CPU: one step, {output, next state} (output nil: skip())
          def unquote(name)(unquote(var), unquote(state_var), unquote_splicing(lvars)) when unquote(guard) do
            unquote(var) = unquote(wrap_code(var, arg_spec))
            unquote_splicing(lwraps)
            unquote(state_var) = unquote(wrap_code(state_var, state_spec))
            unquote(wrap_code(cpu_body, {:tuple, [ret_spec, state_spec]}))
          end

          def unquote(name)(:zero), do: unquote(Macro.escape(init))

          unquote_splicing(table_funs)
        end

      true ->
        quote do
          unquote(write_hw)

          def unquote(name)(unquote(var), unquote_splicing(lvars)) when unquote(guard) do
            unquote(var) = unquote(wrap_code(var, arg_spec))
            unquote_splicing(lwraps)
            unquote(wrap_code(cpu_body, ret_spec))
          end

          unquote_splicing(table_funs)
        end
    end
  end

  @doc false
  # Runs while the module body is evaluated (table attributes are set by then): the kernel's
  # MLIR and its description (.sig, JSON) for mix ehls.compile.
  def __write_kernel__(file, line, dir, sig, params, result, body, tables) do
    EHLS.Error.compile(file, line, fn -> write_kernel(dir, sig, params, result, body, tables) end)
  end

  defp write_kernel(dir, sig, params, result, body, tables) do
    File.mkdir_p!(dir)

    # a pure function whose tables all folded to constants (unrolled) needs no memory space,
    # so no dummy state either (unless it takes or makes tuples)
    {sig, {mlir, space}} =
      with true <- sig.pure and sig.in_words == 1 and sig.out_words == 1,
           [p, _dummy | ps] = params,
           {:tuple, [r, _]} = result,
           {b, 0} = body,
           {_, nil} = plain <- EHLS.MLIR.function(sig.kernel, [p | ps], r, b, tables, sig.lane) do
        {%{sig | pure: false, state: [], init: []}, plain}
      else
        _ -> {sig, EHLS.MLIR.function(sig.kernel, params, result, body, tables, sig.lane)}
      end

    File.write!(Path.join(dir, "#{sig.kernel}.mlir"), mlir)

    space =
      space &&
        %{space | regions: Enum.map(space.regions, fn r ->
          r
          |> Map.take([:kind, :name, :base, :size])
          |> Map.put(:values, Enum.map(Map.get(r, :values, []), &unsigned(&1, 32)))
          # a memory's words are as wide as its element (the kernel uses only those bits)
          |> Map.put(:width, if(r.kind == :ram, do: elem(r.elem, 0), else: 32))
        end)}

    sig = Map.put(sig, :space, space)
    File.write!(Path.join(dir, "#{sig.kernel}.sig"), JSON.encode!(sig))
  end

  # the statements of a body before its last expression, and the last expression: spliced
  # into the CPU clause so that `mem = write(mem, ...)` at the top level stays visible
  defp split_body({:__block__, _, exprs}), do: {Enum.drop(exprs, -1), List.last(exprs)}
  defp split_body(e), do: {[], e}

  # compile time: the initial state
  defp wrap_value(x, {n, s}) when is_integer(x) and is_integer(n), do: wrap(x, n, s)

  defp wrap_value(t, {:tuple, specs}) when is_tuple(t) and tuple_size(t) == length(specs),
    do: t |> Tuple.to_list() |> Enum.zip(specs) |> Enum.map(fn {x, s} -> wrap_value(x, s) end) |> List.to_tuple()

  defp wrap_code(ast, {:emit, spec}) do
    v = Macro.unique_var(:hw_emit, __MODULE__)

    quote do
      case unquote(ast) do
        [] -> []
        [unquote(v)] -> [unquote(wrap_code(v, spec))]
      end
    end
  end

  # a tuple(t, n) of a state: its values were cut as put_elem wrote them
  defp wrap_code(ast, {:mem, _, _}), do: ast
  defp wrap_code(ast, {n, s}) when is_integer(n), do: quote(do: EHLS.wrap(unquote(ast), unquote(n), unquote(s)))

  # a large tuple of one type (tuple(t, n)): each element cut at run time (a pattern of hundreds of variables is more
  # than the Erlang compiler takes)
  defp wrap_code(ast, {:tuple, [{w, sg} | _] = specs}) when length(specs) > 16 and is_integer(w) do
    if Enum.all?(specs, &(&1 == {w, sg})) do
      quote do
        t = unquote(ast)
        unquote(length(specs)) = :erlang.tuple_size(t)
        t |> :erlang.tuple_to_list() |> :lists.map(&EHLS.wrap(&1, unquote(w), unquote(sg))) |> :erlang.list_to_tuple()
      end
    else
      wrap_tuple(ast, specs)
    end
  end

  defp wrap_code(ast, {:tuple, specs}), do: wrap_tuple(ast, specs)

  defp wrap_tuple(ast, specs) do
    vars = for _ <- specs, do: Macro.unique_var(:hw_elem, __MODULE__)
    elems = for {v, s} <- Enum.zip(vars, specs), do: wrap_code(v, s)

    quote do
      {unquote_splicing(vars)} = unquote(ast)
      {unquote_splicing(elems)}
    end
  end

  # KernelDemo + stream_kernel -> kernel_demo_stream_kernel (an SV module name)
  @doc false
  def kernel_name(module, name) do
    base = module |> Macro.underscore() |> String.replace(~r/[^a-z0-9_]/, "_")
    "#{base}_#{name}" |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  # name(x :: t) :: r   or   name(x :: t, st :: state(t)) :: r
  defp parse_head({:"::", _, [{name, _, params}, ret]}) when is_atom(name) and is_list(params) do
    {name, Enum.map(params, &parse_param/1), ret}
  end

  defp parse_head(head) do
    raise ArgumentError,
          "defhls expects `name(arg :: type) :: type` or `name(arg :: type, st :: state(type)) :: type`, got: #{Macro.to_string(head)}"
  end

  defp parse_param({:"::", _, [var, {:memory, _, _} = type]}), do: {var, type, nil}
  defp parse_param({:"::", _, [var, {:tuple, _, [_, _]} = type]}), do: {var, type, nil}
  defp parse_param({:"::", _, [var, type]}), do: {var, type, nil}
  defp parse_param({:\\, _, [{:"::", _, [var, type]}, init]}), do: {var, type, init}
  defp parse_param(p), do: raise(ArgumentError, "defhls: bad parameter #{Macro.to_string(p)}")

  # a result: {[t], s}, an output that may be missing, is {emit(t), s}; a list is no type anywhere else
  defp ret_spec!({[t], st}), do: {:tuple, [{:emit, spec!(t)}, spec!(st)]}
  defp ret_spec!(t), do: spec!(t)

  # type AST -> spec: u16 -> {16, false}; {s16, s16} -> {:tuple, [...]}
  defp spec!({:emit, _, [t]}), do: {:emit, spec!(t)}
  defp spec!({:memory, _, _} = m), do: m
  defp spec!({a, b}), do: spec!({:{}, [], [a, b]})
  defp spec!({:{}, _, types}), do: {:tuple, Enum.map(types, &spec!/1)}
  # tuple(t, n): n values of type t, as {t, t, ...}
  defp spec!({:tuple, _, [t, n]}) when is_integer(n) and n >= 1, do: {:tuple, List.duplicate(spec!(t), n)}
  defp spec!({t, _, ctx}) when is_atom(t) and is_atom(ctx), do: type!(t)
  defp spec!(t), do: raise(ArgumentError, "defhls: bad type #{Macro.to_string(t)}")

  @doc false
  # a type as it is written, for messages and the description; :any and nil pass through
  def type_name(nil), do: nil
  def type_name(:any), do: "any"
  def type_name(spec), do: spec_name(spec)

  @doc false
  # a block's declared type: :u8, or a tuple of them
  def block_type(t) when t in [nil, :any], do: t
  def block_type(t) when is_atom(t), do: type!(t)
  def block_type(t) when is_tuple(t), do: {:tuple, t |> Tuple.to_list() |> Enum.map(&block_type/1)}

  # spec -> type AST, as it is written in a head
  defp spec_ast({:tuple, specs}), do: {:{}, [], Enum.map(specs, &spec_ast/1)}
  defp spec_ast({:emit, spec}), do: {:emit, [], [spec_ast(spec)]}
  defp spec_ast({n, s}), do: {:"#{if s, do: "s", else: "u"}#{n}", [], nil}

  defp spec_name({:emit, spec}), do: spec_name(spec)
  defp spec_name({:tuple, specs}), do: Enum.map(specs, &spec_name/1)
  defp spec_name({n, s}), do: "#{if s, do: "s", else: "u"}#{n}"

  defp flat({:tuple, specs}), do: Enum.flat_map(specs, &flat/1)
  defp flat(spec), do: [spec]

  defp flat_values(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&flat_values/1)
  defp flat_values(x), do: [x]

  defp zero_value({:tuple, specs}), do: specs |> Enum.map(&zero_value/1) |> List.to_tuple()
  # a tuple(t, n) of the state that is no memory: registers, n zeros
  defp zero_value({:mem, n, spec}), do: :erlang.make_tuple(n, zero_value(spec))
  defp zero_value(_), do: 0

  @doc false
  # transform(init, ...): the initial state of a stage as its state words, for its adapter
  # bits: a word's (32: the circuit's ports), or :own, each value cut to its own width (a state is up to 32 bits, so a
  # word is never a big integer on AtomVM)
  def __init_words__(ast, spec, bits \\ 32)

  # a state holding tuples (EHLS.TupleState): the circuit's state is its values, the tuples start from zeros
  def __init_words__(ast, {:layout, layout, spec}, bits), do: __init_words__(layout_init(ast, layout), spec, bits)

  def __init_words__(ast, spec, :own) do
    ast |> init_value!(spec) |> flat_values() |> Enum.zip(flat(spec)) |> Enum.map(fn {v, {w, _}} -> unsigned(v, w) end)
  end

  def __init_words__(ast, spec, bits) do
    ast |> init_value!(spec) |> flat_values() |> Enum.map(&unsigned(&1, bits))
  end

  @doc false
  # the initial value of a state holding tuples, as the CPU takes it (each tuple a literal), and the values of it
  # (layout_init/2), as the circuit's state takes them
  def __tuple_init__(ast, {:layout, layout, _}) do
    value = eval_init!(ast)
    _ = layout_parts!(value, layout)
    Macro.escape(value)
  end

  defp layout_init(ast, layout) do
    case layout_parts!(eval_init!(ast), layout) do
      [] -> 0
      [v] -> Macro.escape(v)
      vs -> Macro.escape(List.to_tuple(vs))
    end
  end

  defp eval_init!(ast) do
    {value, _} = Code.eval_quoted(ast)
    value
  rescue
    e -> raise ArgumentError, "defhls: the initial state is a literal of its type (a tuple(t, n) one too, Tuple.duplicate(0, n)): #{Exception.message(e)}"
  end

  # the values of the state, each tuple checked: n zeros
  defp layout_parts!(value, %{shape: :whole, mems: [{_, _, n}]}) do
    zeros!(value, n)
    []
  end

  defp layout_parts!(value, %{shape: shape}) do
    unless is_tuple(value) and tuple_size(value) == length(shape),
      do: raise(ArgumentError, "defhls: the initial state has #{length(shape)} parts, got #{inspect(value, limit: 8)}")

    for {part, v} <- Enum.zip(shape, Tuple.to_list(value)), reduce: [] do
      acc ->
        case part do
          {:mem, _, n} -> zeros!(v, n) && acc
          {:val, _} -> acc ++ [v]
        end
    end
  end

  defp zeros!(v, n) do
    unless is_tuple(v) and tuple_size(v) == n and Enum.all?(Tuple.to_list(v), &(&1 == 0)),
      do: raise(ArgumentError, "defhls: a tuple(t, #{n}) of the state starts from zeros, Tuple.duplicate(0, #{n}), got #{inspect(v, limit: 8)}")

    true
  end

  defp init_value!(ast, spec) do
    {value, _} = Code.eval_quoted(ast)
    wrap_value(value, spec)
  rescue
    e -> raise ArgumentError, "defhls: the initial state must be a literal of its type: #{Exception.message(e)}"
  end

  # u1..u64 / s1..s64 (a kernel's ports: 32 or 64 bits)
  defp type!(t) do
    case Regex.run(~r/^([us])(\d+)$/, Atom.to_string(t)) do
      [_, k, n] when n != "0" ->
        n = String.to_integer(n)
        if n > 64, do: raise(ArgumentError, "defhls: #{t}: up to 64 bits")
        {n, k == "s"}

      _ ->
        raise ArgumentError, "defhls: unknown type #{t} (u1..u64, s1..s64)"
    end
  end
end
