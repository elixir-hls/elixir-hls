# はじめに

Elixir で関数を書き、FPGA に配置して、CPU で動く Elixir から呼ぶところまでです。呼ぶと、FPGA の回路で計算した結果が
返ってきます。まず値を 1 つずつ、次にたくさんの値をストリームとして扱います。ボードに載せる前に、同じ回路を手元の
シミュレーションで確かめます。

実行には、Elixir HLS が対応している FPGA ボードを使います。今、対応しているボードは Sipeed Tang Primer 25K です。
Elixir HLS は、ハードウェアに依存する部分をバックエンド（`EHLS.Backend`）として分けているので、使いたい
ボードのバックエンドを作って使うこともできます。このガイドでは Tang Primer 25K で説明します。

## 1. 必要なもの

**手元で回路を作って確かめるために:**

- Elixir 1.18 以降と、python3。
- シミュレータの Icarus Verilog。Ubuntu / Debian では `sudo apt install iverilog`、macOS では `brew install icarus-verilog`。
- CIRCT 1.160.0（LLVM のプロジェクトの、回路のためのコンパイラ）の 2 つのプログラム、`hlstool` と `mlir-opt`。
  リリースは 1 GB を超えるので、次のようにこの 2 つだけを取り出します（Linux、x86-64）。

```sh
mkdir -p ~/tools/circt-1.160.0/bin
curl -fsSL https://github.com/llvm/circt/releases/download/firtool-1.160.0/circt-full-static-linux-x64.tar.gz |
  tar -xz -C ~/tools/circt-1.160.0/bin --strip-components=2 --wildcards '*/bin/hlstool' '*/bin/mlir-opt'
export CIRCT_BIN=~/tools/circt-1.160.0/bin      # シェルの設定ファイルにも書いておきます
```

**ボードで動かすために:**

- Sipeed Tang Primer 25K と Dock、SDRAM モジュール。
- Gowin IDE、openFPGALoader、Zephyr のワークスペースと SDK。
- ボードの土台 [atomvm-tang25k](https://github.com/elixir-hls/atomvm-tang25k)（LiteX の SoC と AtomVM）のために、
  rebar3 を含む Erlang/OTP、cmake、ninja、gperf。土台そのものはプロジェクトと一緒に入り、`mix ehls.setup`（2 章）で
  用意します。

## 2. プロジェクト

新しいプロジェクトを作る `mix ehls.new` を、最初に一度だけインストールします。ほかに何も必要としない archive です。

```sh
mix archive.install hex ehls_new
```

そのうえで、次のようにします。

```sh
mix ehls.new first_kernel         # Tang Primer 25K 向け（--target tang25k が既定）
cd first_kernel
mix deps.get
mix ehls.setup                    # マシンに一度だけ: ボードの土台（LiteX、AtomVM。数十分）
```

`mix ehls.setup` は、用意したものを `~/.cache/ehls` に土台の版ごとに置きます。そのマシンのプロジェクトはそれを共有し、
同じ版を使う別のプロジェクトは、用意済みのものをそのまま使います。

できたプロジェクトの `mix.exs` には Tang Primer 25K のターゲットが依存関係として入っていて、Elixir HLS もそれと一緒に入ります。
プロジェクトには、例の `lib/first_kernel.ex` とそのテスト（`mix test`）、ボードまでの手順を書いた README も入っています。
このガイドでは、その例の隣に自分のモジュールを書いていきます。

## 3. 関数を書く

`lib/first.ex`:

```elixir
defmodule First do
  use EHLS

  # the larger of the two 16-bit halves, times three
  defhls larger(x :: u32) :: u32 do
    a = x &&& 0xFFFF
    b = x >>> 16
    if a > b, do: a * 3, else: b * 3
  end

  defhls plus_one(x :: u32) :: u32 do
    x + 1
  end

  defhls larger_plus_one(x :: u32) :: u32 do
    plus_one(larger(x))
  end
end
```

どれも、1 つの値を受け取って 1 つの値を返す関数です。`larger_plus_one` はほかの 2 つを呼びます。`u32`（符号なし 32 ビット）
のような型は、回路での値の幅です。

`defhls` で書いた関数は、普通の Elixir の関数でもあります。`iex -S mix` で呼べます。

```elixir
iex> First.larger(0x0002_0005)
15
iex> First.larger_plus_one(0x0002_0005)
16
```

## 4. FPGA に配置する

`defhls` は関数の定義です。定義しただけでは、FPGA に回路は置かれません。`definstance` で、関数を実体として FPGA に配置
します。`First` に次を加えます。

```elixir
  definstance larger_plus_one_hw(x :: u32) do
    larger_plus_one(x)
  end
```

引数に型を付けたインスタンスは、値を受け取って値を返します。CPU で `larger_plus_one_hw(0x0002_0005)` を呼ぶと、引数が
回路に書き込まれ、回路が計算し、その結果が返ってきます。結果は次に呼ぶまで回路に保たれていて、
`larger_plus_one_hw(:value)` でもう一度読めます。

処理は `defhls` で書き、`definstance` にはその関数を置くのが基本です。

## 5. ボードに載せる前に確かめる

ここは、開発に使うホストの PC で実行します（ボードは要りません）。

まず、配置したインスタンスをホストの PC で呼んで、結果を見ます。ボードがないので、インスタンスはホストの PC の上で、
Elixir の関数として動きます。

```elixir
iex> First.larger_plus_one_hw(0x0002_0005)
16
iex> First.larger_plus_one_hw(:value)
16
```

次に、回路を作り、関数と同じ結果になるかをシミュレーションで確かめます。

```sh
mix ehls.compile lib/first.ex     # ホストの PC で
mix ehls.sim lib/first.ex         # ホストの PC で
```

`mix ehls.compile` は、CIRCT で関数ごとの回路を SystemVerilog にし、iverilog で関数と比べます。テストは自動で作られます。
入力は境界の値と乱数で、期待値は同じ関数を Elixir で動かした結果です（詳しくは `mix help ehls.compile`）。
`mix ehls.sim` は、配置したものを CPU と同じように使って確かめます。ランダムな値で呼び、前の計算が終わる前に次を
呼ぶことも混ぜて、保たれた結果を 1 つずつ確かめます。最後に出る行の中に、次のような行があります。

```
RESULT first_larger_plus_one_hw__level: vectors=2011 errors=0 latency=2..2   First.larger_plus_one_hw__level (u32 -> u32, 0 state words)
RESULT larger_plus_one_hw[0..0]: calls=2000 held=1603 errors=0
```

`errors=0` は、回路が関数と同じ結果を出したということです。合わない回路があると、そこで止まります。

## 6. ボードで動かす

このボードでは、CPU で AtomVM が動いていて、アプリは AtomVM の決まりどおり `start/0` から始まります。`First` に次を加えます。

```elixir
  def start do
    IO.inspect(larger_plus_one_hw(0x0002_0005))
    IO.inspect(larger_plus_one_hw(:value))
  end
```

`config/config.exs` で、ボードで最初に動かすモジュールを `First` にします。

```elixir
config :elixir_hls, target: :tang25k, start: First
```

`mix ehls.run` が、回路を FPGA のシステム（SoC）に組み込み、ボードに書き込んで動かします。

```sh
mix ehls.doctor      # 最初に一度: このマシンにあるもの、足りないもの
mix ehls.run         # 回路（mix ehls.compile と同じく確かめる）、SoC（Gowin で数分）、その SoC 用の AtomVM、
                     # アプリを作り、ボードに送って動かし、コンソールを表示する
```

コンソールに、ボードの回路で計算した結果が出ます。3 章で CPU の `larger_plus_one` が返したのと同じです。

```
16
16
```

`mix ehls.run` は、前回から変わったところだけを作り直します。`start/0` だけを変えたときは、アプリだけを作り直し、SoC
は作り直しません。Gowin IDE が自動で見つからないときは、このマシンでの場所を `config/local.exs`
に書きます（どれが必要かは `mix ehls.doctor` が示します）。SoC がタイミングを満たさないときは、
`deps/atomvm_tang25k_hls/scripts/sweep_soc.sh` で配置の設定を探します。ボードの電源を入れた直後や書き込みの直後に
実行が失敗したときは、もう一度実行します。

## 7. たくさんの値: ストリーム

値が次々に来るとき（音のサンプル、一定の間隔で読むセンサー）は、回路はそれをストリームとして受け取ります。値は
1 つずつ順に関数を通り、前の値を計算している間に次の値が入ってきます。型のない引数がストリームで、`map(&f/1)` は
1 つ 1 つの値を `f` に通します。`First` に次を加えます。

```elixir
  defhls scale(x :: u32, k :: u8) :: u32 do
    x * k
  end

  # a value the CPU sets: k_hw(10) makes it 10
  definstance k_hw(k :: u8), initial: 1 do
    k
  end

  # each value through larger_plus_one, then times what k_hw holds
  definstance many_hw(words) do
    words |> map(&larger_plus_one/1) |> map(&scale(&1, k_hw(:value)))
  end
```

`many_hw` は同じ `larger_plus_one` を配置し、Elixir と同じようにパイプ（`|>`）で `scale` をつないでいます。`scale` の `k`
は `k_hw` の値につながっています。`definstance` の中の `k_hw(:value)` は、CPU で同じ式が値を読むのと同じく、その値への
配線です。リストを渡すとリストが返ります。

```elixir
  def start do
    IO.inspect(larger_plus_one_hw(0x0002_0005))
    IO.inspect(larger_plus_one_hw(:value))
    IO.inspect(many_hw([0x0002_0005, 1, 0x0001_0000]))
    k_hw(10)
    IO.inspect(many_hw([0x0002_0005, 1, 0x0001_0000]))
  end
```

もう一度動かします（`mix ehls.run`）。

```
16
16
[16, 4, 4]
[160, 40, 40]
```

リストの要素が 1 つずつ回路を通りました。`k_hw(10)` の後は、同じストリームが 10 倍で出てきます。リストの代わりに
binary を渡すこともでき、そのときは binary が返ります。

## 次に読むもの

- [Elixir HLS の考え方](concepts.ja.md): `defhls` と `definstance`、値、ハードウェアにできる書き方、ストリーム（2 つの合流、
  1 つを 2 か所で使う分岐、インスタンスの中のインスタンス）、CPU とのやり取り、イベント、FPGA か CPU か（インスタンスの
  置き場所、インスタンスの関数を 1 つ CPU で動かす）。
- リファレンス（英語。HexDocs のモジュールの説明）: `EHLS.defhls/2`（関数に書けるもの: 型、式、状態を持つ関数、メモリ、
  レベル）、`EHLS.Pipeline`（インスタンスと CPU からの呼び出し）、`EHLS.Stream`（インスタンスがつなぐ関数）、`EHLS.Agent`、
  `EHLS.PubSub`（イベント）、`EHLS.Server`、`EHLS.GPIO`、`EHLS.Backend`。
- [atomvm-tang25k-hls](https://github.com/elixir-hls/atomvm-tang25k-hls): ボードのスクリプト、タイミング、サンプル。ピンの小さな例は
  [`gpio_demo.ex`](https://github.com/elixir-hls/atomvm-tang25k-hls/blob/main/examples/lib/gpio_demo.ex)（ボードの LED とボタン）。
- [atomvm-fm-radio](https://github.com/elixir-hls/atomvm-fm-radio): 動く例。FM ステレオ放送の復調をすべて Elixir で書き、FPGA で
  動かす受信機。
