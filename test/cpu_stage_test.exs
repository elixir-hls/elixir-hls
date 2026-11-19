defmodule EHLS.CpuStageTest do
  use ExUnit.Case

  # `on: :cpu`: an instance cut in two, with the driver's functions between
  @moduletag :tmp_dir

  defp compile(src, dir) do
    System.put_env("EHLS_OUT_DIR", dir)

    try do
      Code.compile_string(src)
    after
      System.delete_env("EHLS_OUT_DIR")
    end
  end

  test "a stage on the CPU cuts the instance into __pre and __post", %{tmp_dir: dir} do
    compile(
      """
      defmodule CutDemo do
        use EHLS

        defhls inc(x :: u32) :: u32 do
          x + 1
        end

        defhls big(x :: u32) :: u32 do
          x * 3
        end

        defhls low(x :: u32) :: u16 do
          x &&& 0xFFFF
        end

        definstance cut(words) do
          words |> map(&inc/1) |> map(&big/1, on: :cpu) |> map(&low/1)
        end

        definstance last_on_cpu(words) do
          words |> map(&inc/1) |> map(&big/1, on: :cpu)
        end

        defhls running(x :: u32, acc :: u32) :: {u32, u32} do
          {acc + x, acc + x}
        end

        definstance with_state(words) do
          words |> map(&inc/1) |> transform(5, &running/2, on: :cpu) |> map(&low/1)
        end
      end
      """,
      dir
    )

    pipes = dir |> Path.join("*.pipeline") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()
    assert pipes == [
             "cut_demo_cut__post.pipeline",
             "cut_demo_cut__pre.pipeline",
             "cut_demo_last_on_cpu__pre.pipeline",
             "cut_demo_with_state__post.pipeline",
             "cut_demo_with_state__pre.pipeline"
           ]

    pre = dir |> Path.join("cut_demo_cut__pre.pipeline") |> File.read!() |> JSON.decode!()
    assert [%{"kernel" => "cut_demo_inc"}] = pre["stages"]
    assert %{"overflow" => "wait"} = pre["output"]

    post = dir |> Path.join("cut_demo_cut__post.pipeline") |> File.read!() |> JSON.decode!()
    assert [%{"kernel" => "cut_demo_low"}] = post["stages"]
    assert [%{"name" => "cpu_in", "type" => "u32"}] = post["inputs"]

    # the NIF is not in either: it is the CPU's
    refute File.read!(Path.join(dir, "cut_demo_cut__pre.pipeline")) =~ "cut_demo_big"

    assert function_exported?(CutDemo, :cut, 2)
    assert function_exported?(CutDemo, :last_on_cpu, 2)
    assert function_exported?(CutDemo, :with_state, 2)
  end

  test "a stage with state needs transform, one without map", %{tmp_dir: dir} do
    msg = fn src -> assert_raise(CompileError, fn -> compile(src, dir) end).description end

    base = """
    defhls inc(x :: u32) :: u32 do
      x + 1
    end

    defhls running(x :: u32, acc :: u32) :: {u32, u32} do
      {acc + x, acc + x}
    end
    """

    assert msg.("defmodule CutS1 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&inc/1) |> map(&running/1, on: :cpu)\nend\nend") =~ "transform(init, &running/2, on: :cpu)"
    assert msg.("defmodule CutS2 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&inc/1) |> transform(0, &inc/2, on: :cpu)\nend\nend") =~ "has no state: map"
    assert msg.("defmodule CutS3 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&inc/1) |> transform(0, &running/2, on: :cpu, name: :a)\nend\nend") =~ "takes only on:"
  end

  test "what cannot be cut says so", %{tmp_dir: dir} do
    msg = fn src -> assert_raise(CompileError, fn -> compile(src, dir) end).description end

    assert msg.("""
           defmodule CutNoPre do
             use EHLS
             defhls big(x :: u32) :: u32 do
               x * 3
             end
             definstance cut(words) do
               words |> map(&big/1, on: :cpu)
             end
           end
           """) =~ "nothing between the argument and the stage on the CPU"
  end

  test "the types at the cut must be the same", %{tmp_dir: dir} do
    msg = fn src -> assert_raise(CompileError, fn -> compile(src, dir) end).description end

    base = """
    defhls small(x :: u32) :: u8 do
      x &&& 0xFF
    end

    defhls wide(x :: u16) :: u16 do
      x + 1
    end

    defhls byte(x :: u8) :: u8 do
      x + 1
    end

    defhls head(x :: u32) :: u32 do
      x + 1
    end
    """

    # a u8 is not a u16 across the cut, though the FPGA would widen it
    assert msg.("defmodule CutT1 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&small/1) |> map(&wide/1, on: :cpu)\nend\nend") =~
             "small gives u8 and wide takes u16"

    assert msg.("defmodule CutT2 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&head/1) |> map(&byte/1, on: :cpu)\nend\nend") =~
             "head gives u32 and byte takes u8"

    # after the stage
    assert msg.("defmodule CutT3 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&small/1) |> map(&byte/1, on: :cpu) |> map(&wide/1)\nend\nend") =~
             "byte gives u8 and wide takes u16"

    # the same types: fine
    compile("defmodule CutT4 do\nuse EHLS\n#{base}\ndefinstance c(w) do\nw |> map(&small/1) |> map(&byte/1, on: :cpu)\nend\nend", dir)
    assert function_exported?(CutT4, :c, 2)
  end

  test "several stages on the CPU: the FPGA between them is an instance of its own", %{tmp_dir: dir} do
    compile(
      """
      defmodule CutMany do
        use EHLS

        defhls a(x :: u32) :: u32 do
          x + 1
        end

        defhls c1(x :: u32) :: u32 do
          x * 3
        end

        defhls c2(x :: u32) :: u32 do
          x * 5
        end

        defhls mid(x :: u32) :: u32 do
          x + 7
        end

        defhls z(x :: u32) :: u16 do
          x &&& 0xFFFF
        end

        # two CPU stages in a row are one driver; the FPGA between two runs of them an instance
        definstance run(w) do
          w |> map(&a/1) |> map(&c1/1, on: :cpu) |> map(&c2/1, on: :cpu) |> map(&mid/1) |> map(&c1/1, on: :cpu) |> map(&z/1)
        end
      end
      """,
      dir
    )

    pipes = dir |> Path.join("*.pipeline") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()
    assert pipes == ["cut_many_run__1.pipeline", "cut_many_run__post.pipeline", "cut_many_run__pre.pipeline"]

    kernels = fn f -> dir |> Path.join(f) |> File.read!() |> JSON.decode!() |> Map.fetch!("stages") |> Enum.map(& &1["kernel"]) end
    assert kernels.("cut_many_run__pre.pipeline") == ["cut_many_a"]
    assert kernels.("cut_many_run__1.pipeline") == ["cut_many_mid"]
    assert kernels.("cut_many_run__post.pipeline") == ["cut_many_z"]
    assert function_exported?(CutMany, :run, 2)
  end

  test "the types between two stages on the CPU are checked too", %{tmp_dir: dir} do
    msg =
      assert_raise(CompileError, fn ->
        compile(
          """
          defmodule CutMany2 do
            use EHLS
            defhls a(x :: u32) :: u32 do
              x + 1
            end
            defhls narrow(x :: u32) :: u8 do
              x &&& 0xFF
            end
            defhls wide(x :: u16) :: u16 do
              x + 1
            end
            definstance run(w) do
              w |> map(&a/1) |> map(&narrow/1, on: :cpu) |> map(&wide/1, on: :cpu)
            end
          end
          """,
          dir
        )
      end).description

    assert msg =~ "narrow gives u8 and wide takes u16"
  end

  test "a function of several arguments on the CPU takes them where it is placed", %{tmp_dir: dir} do
    msg =
      assert_raise(CompileError, fn ->
        compile(
          """
          defmodule CutLevel do
            use EHLS
            defhls a(x :: u32) :: u32 do
              x + 1
            end
            defhls volume(x :: u32, g :: u9) :: u32 do
              x * g
            end
            definstance run(w) do
              w |> map(&a/1) |> map(&volume/2, on: :cpu) |> map(&a/1)
            end
          end
          """,
          dir
        )
      end).description

    assert msg =~ "volume on the CPU takes its other arguments where it is placed"
  end

  test "a level wired into a function on the CPU: a kernel made for it, its levels read by the driver", %{tmp_dir: dir} do
    # the driver is the target's (priv/backend/atomvm/lib): a stand-in giving back what it is started with
    Code.compile_string("""
    defmodule EHLS.CpuDriver do
      def start(spec), do: spec
    end
    """)

    compile(
      """
      defmodule CutLevels do
        use EHLS
        defhls inc(x :: u32) :: u32 do
          x + 1
        end
        defhls volume(x :: u32, g :: u9) :: u32 do
          x * g
        end
        definstance gain(g :: u9), initial: 6 do
          g
        end
        definstance radio(words) do
          words |> map(&inc/1) |> map(&volume(&1, gain(:value)), on: :cpu) |> map(&inc/1)
        end
        definstance fixed(words) do
          words |> map(&inc/1) |> map(&volume(&1, 3), on: :cpu) |> map(&inc/1)
        end
      end
      """,
      dir
    )

    # the kernels made, as for the FPGA: a level argument, or the integer in the kernel
    sigs = dir |> Path.join("*.sig") |> Path.wildcard() |> Enum.map(&Path.basename/1)
    assert "cut_levels_volume__x_l.sig" in sigs
    assert "cut_levels_volume__x_c3.sig" in sigs

    radio = CutLevels.radio(:cpu_start, [])
    assert radio.kernels == [{:"CutLevels.volume__x_l", nil}]
    # the level read before each batch, as the CPU reads it: here no board, so the call says so
    levels = Keyword.fetch!(radio.opts, :levels)
    assert_raise ArgumentError, ~r/runs on a board/, fn -> levels.(:"CutLevels.volume__x_l") end
    assert levels.(:"CutLevels.other") == []

    # an integer is in the kernel: no level to read
    fixed = CutLevels.fixed(:cpu_start, [])
    assert fixed.kernels == [{:"CutLevels.volume__x_c3", nil}]
    refute Keyword.has_key?(fixed.opts, :levels)

    # what the application says comes first
    mine = fn _ -> [1] end
    assert Keyword.fetch!(CutLevels.radio(:cpu_start, levels: mine).opts, :levels) == mine
  after
    for m <- [EHLS.CpuDriver, CutLevels] do
      :code.purge(m)
      :code.delete(m)
    end
  end
end
