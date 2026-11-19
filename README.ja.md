# elixir-hls

[English](README.md) | 日本語

Elixir HLS は、Elixir で書いた関数から FPGA の回路を作る、高位合成（HLS: High-Level
Synthesis）のツールです。

## 高位合成とは

FPGA の回路は、ふつう Verilog や VHDL などのハードウェア記述言語で書きます。そこでは、
どのクロックで、どのレジスタに、どの値を入れるかを、ひとつずつ書いていきます。この書き方を
RTL（Register Transfer Level）と呼びます。高位合成は、ソフトウェアの言語で書いた処理から、
この RTL を自動で作る技術です。書く人は「何を計算するか」に集中でき、クロックやレジスタの
割り当ては、ツールが決めます。

Elixir HLS では、元になる言語が Elixir です。`defhls` で定義した関数は、ふだんの Elixir の
関数として CPU で動き、同時に FPGA の回路にもなります。作った回路は、元の Elixir の関数と
シミュレーションで比べ、結果が一致することを確かめてから使います。そのため、Elixir の関数が
そのまま回路の仕様になります。なぜこの形にしたのかは、[構想](docs/vision.ja.md)に書いて
います。

## 現状

Elixir HLS 0.1.0 は最初のリリースで、まだ初期の段階です。整数の関数（状態、表、メモリ、回数の決まったループを含む）と、それらをストリーム、
レベル、イベントでつなぐインスタンスを合成し、FPGA でも CPU でも動かせます。最初のターゲットは Sipeed Tang Primer 25K と
AtomVM で、動く例は FM ラジオ（[atomvm-fm-radio](https://github.com/elixir-hls/atomvm-fm-radio)）です。復調のすべてが
FPGA で動きます。まだないものは、割り算、浮動小数点数、再帰、Elixir のストリームのうち全体がそろう必要があるもの、などです。

## 例

```elixir
defmodule KernelDemo do
  use EHLS

  defhls stream_kernel(x :: u32) :: u32 do
    a = signed(x &&& 0xFFFF, 16)
    b = signed(x >>> 16, 16)
    if a > b, do: a * 3 + b, else: a + b * 2
  end
end

KernelDemo.stream_kernel(123)        # => 369（CPU で計算する）
```

`stream_kernel` は、32 ビットの値を受け取り、下位の 16 ビットと上位の 16 ビットを符号付きの
数として比べて、その結果で計算を変える関数です。整数を渡すと、CPU で、Elixir の関数として
計算します。同じ関数を FPGA の回路として動かす方法は、[ボードで動かす](#ボードで動かす)で
説明します。

`u32`（符号なし 32 ビット）のような型は、回路のビット幅になります。回路はビット幅の分だけ
配線と論理を使うので、幅を必要なだけに絞ると、回路が小さく速くなります。CPU で計算する
ときも、値をこの型の幅に合わせて切り詰めるので、CPU と回路は同じ結果になります。

```sh
mix ehls.compile --out build lib/kernel_demo.ex
```

`mix ehls.compile` は、ファイルの中の `defhls` の関数を、それぞれ SystemVerilog の回路にします。
そのあと、どの回路も、元の関数とシミュレーションで照合します。一致しない回路があれば、
そこで止まります。

## Elixir と Elixir HLS

### 書けるもの

`defhls`（CPU でも回路としても動く関数）と `definstance`（インスタンスの定義。関数を回路として置く）で書けるものを、
Elixir の書き方と並べます。✗ は書けないものです。詳しくは [Elixir HLS の考え方](docs/concepts.ja.md)、`EHLS.defhls/2`、
`EHLS.Pipeline`、`EHLS.Stream` にあります。

**値と型**（`defhls`）

| 項目 | Elixir | Elixir HLS |
|---|---|---|
| 整数 | `integer()`（大きさは任意） | `u8`、`s16` など（`u` は符号なし、`s` は符号あり、数字はビット数 1〜64）。幅を超えた分は折り返す |
| 型の書き方 | `@spec f(integer()) :: integer()`（なくてもよい） | `defhls f(x :: u8) :: u16`（必ず書く） |
| タプル | `{integer(), integer()}` | `{u8, s16}`。同じ型が並ぶものは `tuple(s16, 32)` とも書ける |
| 浮動小数点数 | `float()` | ✗ |
| アトム、文字列、マップ | `atom()`、`String.t()`、`map()` | ✗ |
| リスト | `[integer()]` | ✗（CPU からは、リストでインスタンスを呼べる） |
| 定数の表 | `Enum.at(@t, i)` | 同じ（回路の中の表になる） |

**関数の定義**（`defhls`）

| 項目 | Elixir | Elixir HLS |
|---|---|---|
| 定義 | `def f(x) do ... end` | `defhls f(x :: u8) :: u8 do ... end`（Elixir の関数でもある） |
| 演算 | `+ - *`、`Bitwise`、`== <`、`and or not` | 同じ |
| 割り算 | `div`、`rem`、`/` | ✗ |
| 分岐 | `if`、`case`、`cond`、複数の節とガード | 同じ（最後の節はすべてに一致すること） |
| 呼び出し | `g(x)` | 同じモジュールの `defhls` だけ（呼んだ場所ごとに回路ができる） |
| for ループ | `for k <- 0..15, reduce: acc do ... end` | 同じ（範囲は定数。1 つの回路を繰り返し使う） |
| reduce | `Enum.reduce(0..15, acc, fn k, acc -> ... end)` | 同じ（範囲は定数。回路を回数だけ並べる） |
| 状態の中のタプル | `elem(t, i)`、`put_elem(t, i, v)` | 同じ（回路ではレジスタ。`transform` の `memory:` で FPGA のメモリに） |
| 再帰 | `def f(n), do: f(n - 1)` | ✗ |
| 無名関数 | `fn x -> x + 1 end` | ✗ |
| 例外、メッセージ、入出力 | `raise`、`receive`、`IO.puts` | ✗ |

**ストリームを扱う関数**

| 項目 | Elixir | Elixir HLS |
|---|---|---|
| map | `Stream.map(&f/1)` | `EHLS.Stream.map(&f/1)`（モジュール名は省ける: `map(&f/1)`） |
| filter | `Stream.filter(&f/1)` | `EHLS.Stream.filter(&f/1)` |
| transform | `Stream.transform(0, &f/2)` | `EHLS.Stream.transform(0, &f/2)`（`f` は `defhls` の関数） |
| zip_with | `Stream.zip_with(a, b, &f/2)` | `EHLS.Stream.zip_with(a, b, &f/2)` |
| chunk_every | `Stream.chunk_every(32, 4, :discard)` | `EHLS.Stream.chunk_every(32, 4, :discard)`（長さ 32 のタプルを返す。Elixir はリストで返すので、型が違う） |
| run | `Stream.run()` | `EHLS.Stream.run()` |
| 一定の間隔 | `Stream.interval(1)` | `ticks(1000)`（1 秒あたりの回数） |
| 要素を増やす | `Stream.flat_map(fn x -> [x, x] end)` | ✗ |
| 全体が要るもの | `Enum.sort()`、`Enum.take(n)` | ✗ |
| 2 本をつなげる | `Stream.concat(a, b)` | ✗ |

**状態の共有とイベント**（`definstance`）

| 項目 | Elixir | Elixir HLS |
|---|---|---|
| 状態の共有 | `Agent` | `EHLS.Agent`（違いは `EHLS.Agent` を参照） |
| イベント | `Phoenix.PubSub` | `EHLS.PubSub`（違いは `EHLS.PubSub` を参照） |
| プロセスを作る | `spawn`、`Task` | ✗ |

### Elixir に加わるもの

`definstance` は関数を回路として配置し（FPGA がなければ CPU のプロセスとして）、アプリケーションが呼べる新しいものを加えます。

- **インスタンスの呼び出し**は、関数の呼び出しと同じです。`my_inst(x)` は配置した関数の結果を返し、`my_inst(list)`（または
  binary）は結果のリストを返します。呼んだプロセスは `receive` で待ち、ほかのプロセスは動き続けます。メッセージで受け取る
  呼び方もあります（`my_inst(:send, :x, data)`、`my_inst(:request, :out, n)`）。要素 1 つなら DMA を使わずに
  `my_inst(:send, :x, 5)` で入れられます。状態は `my_inst(:state, n)` で読みます。
- **CPU で設定した値を回路で使う:** 値のインスタンス（`definstance gain_hw(g :: u9)`）に CPU が値を設定し（`gain_hw(12)`）、
  回路の関数はそれを引数として使います（`map(&volume(&1, gain_hw(:value)))`）。値が変わるたびに要素が 1 つ来る
  ストリームにもできます（`changes(gain_hw(:value))`）。
- **動く場所:** FPGA があれば FPGA、なければ CPU で、呼び方は同じです。`on: :cpu | :fpga` で指定でき、インスタンスの関数 1 つ
  だけを CPU に置くこともできます。
- **ピンとデバイスを回路の中で:** ボタンやセンサーのピン、音、USB を、CPU を通さずに回路の関数とつなげます。
  `changes(:button0, :rising) |> transform(0, &count/2) |> pin_out(:led0)` は、ボタンを押すたびに数え、その最下位
  ビットを LED に出す回路（押すたびに点いたり消えたりする）になります。音や USB はパッケージのブロックとして置きます（`x |> i2s_out()`、`usb_bulk_in()`）。CPU からは
  `EHLS.GPIO.read(:pin)`、`EHLS.GPIO.write(:pin, v)` でピンを読み書きできます。
- **テスト:** `defhls` の関数は Elixir の関数で、`mix test` ではインスタンスも CPU で動きます。`mix ehls.compile` と
  `mix ehls.sim` は、各回路を元の関数と照合します。
- **GenServer としてのインスタンス:** `EHLS.Server` で包むと、インスタンスを GenServer と同じに扱えます（監視ツリーに入り、
  アプリケーションと一緒に起動し、呼び出しは順番を待つ）。`GenServer` との違いは `EHLS.Server` を参照。

## 必要なもの

- Elixir 1.18 以降
- CIRCT 1.160.0 の配布バイナリ（`hlstool` と `mlir-opt`）。CIRCT は、LLVM のプロジェクトの
  一つで、回路を作るためのコンパイラの基盤です。展開したディレクトリを、環境変数
  `CIRCT_BIN` に設定します（例: シェルの設定に
  `export CIRCT_BIN=$HOME/tools/circt-1.160.0/bin`）。
- python3
- Icarus Verilog（iverilog。12.0 で確かめています）。回路のシミュレーションに使います。
  Ubuntu / Debian では `sudo apt install iverilog`、macOS では `brew install icarus-verilog`
  で入ります。

## プログラムの例

`defhls` は、合成できる関数の定義で、CPU でも動きます。
`definstance` は、回路を 1 つ FPGA に置きます。いちばん簡単なインスタンスは値を受け取って値を返し、CPU から関数のように
呼べます。次々に来る値（ストリーム）を受け取るインスタンスもあり、リセット直後から動き続けて、デバイスからカーネルへと
CPU を通らずにデータを流すこともできます。

```elixir
defmodule InstanceDemo do
  use EHLS

  defhls stream_kernel(x :: u32) :: u32 do
    a = signed(x &&& 0xFFFF, 16)
    b = signed(x >>> 16, 16)
    if a > b, do: a * 3 + b, else: a + b * 2
  end

  # 値を受け取って値を返す。CPU が書き込み、回路が計算し、結果が保たれる
  definstance kernel_hw(x :: u32) do
    stream_kernel(x)
  end

  # ストリーム: CPU の値を次々にカーネルに通して、CPU に返す
  definstance accel(words) do
    words |> map(&stream_kernel/1)
  end

  # ticks が 1 秒に 1,000 回カウンタの値を出し、それをカーネルに通して、CPU に返す
  definstance demo do
    ticks(1000) |> map(&stream_kernel/1)
  end
end

InstanceDemo.stream_kernel(0x0002_0001)       # 5。CPU で計算する
InstanceDemo.kernel_hw(0x0002_0001)           # 5。FPGA で計算する
InstanceDemo.accel([0x0002_0001])            # [5]。ストリーム。リストを渡すとリストが返る
InstanceDemo.accel(<<1, 0, 2, 0>>)            # binary を渡すと binary が返る
InstanceDemo.demo(:out, 4)                    # 4 つの値を受け取る
```

この先（ボードがなくてもできること、ボードで動かす手順）は、[はじめに](docs/getting_started.ja.md)を見てください。

## 資料

- [はじめに](docs/getting_started.ja.md): 関数を書いてから、ボードの回路で動かすまで
- リファレンス（英語。HexDocs のモジュールの説明）: `EHLS.defhls/2`（型と式、状態、メモリ、レベル、ループ、
  ストリーム関数）、`EHLS.Pipeline`（インスタンス、レベル・イベント・ストリーム、CPU からの呼び出し）、`EHLS.Stream`（インスタンスがつなぐ関数。`Stream` と同じ名前）、`EHLS.Agent`（複数の行で 1 つの状態）、`EHLS.PubSub`（トピック: イベント）、`EHLS.GPIO`（ピン）、
  `EHLS.Server`（GenServer としてのインスタンス）、`EHLS.Backend`（バックエンドの選び方、ターゲットに渡すファイル）
- [Elixir HLS の考え方](docs/concepts.ja.md): `defhls` と `definstance`、値、ハードウェアにできる書き方、ストリーム（合流、分岐、
  インスタンスの中のインスタンス）、CPU とのやり取り、読むまでの動作
- [用語集](docs/glossary.md)
- このリポジトリのテスト: `mix test`（MLIR と回路の説明の生成、CPU での計算）、`EHLS_TEST_CIRCT=1 mix test`（すべての例を CIRCT と iverilog にも通す。数分かかります）
- [構想](docs/vision.ja.md): なぜ作るのか、層の構成、予定
- [設計](docs/design.ja.md): Elixir の関数が回路になるまでの内部の流れ

`mix docs` で、これらの資料とモジュールのドキュメント（上のモジュール、バックエンド、mix タスク）を
HexDocs と同じ HTML として `doc/` に作ります。

## ライセンス

Apache-2.0（[LICENSE](LICENSE) を参照）。
