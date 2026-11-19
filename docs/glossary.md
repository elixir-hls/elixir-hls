# Elixir HLS — Glossary / 用語集

One term each, used the same way in both languages. / 1 つの概念に 1 つの用語を、両方の言語で同じように使います。

| English | 日本語 | Meaning / 意味 |
|---|---|---|
| kernel | カーネル | The circuit of one `defhls` function, made where it is placed: one element in, one result out. / 配置した `defhls` の関数 1 つの回路。ストリームの 1 要素を受け取り、1 つの結果を返す。 |
| function with state | 状態を持つ関数 | A `defhls` of the element and a state, its second argument, giving `{output, next_state}`: the shape of the function `Stream.transform/3` takes. Placed with `transform(init, &f/2)`, the state starts at `init` and is registers; on the CPU it is a plain function. A missing output is a list of at most one, `{[y], s}` / `{[], s}`. / 要素と状態（2 つ目の引数）を受け取り、`{出力, 次の状態}` を返す `defhls`。Elixir の `Stream.transform/3` に渡す関数と同じ形。`transform(init, &f/2)` で置くと、状態は `init` から始まり、レジスタになる。CPU では普通の関数。出力のない入力は、要素 1 つまでのリスト `{[y], s}` / `{[], s}` で書く。 |
| instance | インスタンス | Functions placed with `definstance`, one alone or several joined with the pipe (`|>`): in the FPGA, running from reset, where there is one; else a process on the CPU. / `definstance` で配置したもの。関数 1 つだけのことも、いくつかをパイプ（`|>`）でつなぐこともある。FPGA があれば FPGA に置かれてリセット直後から動き、なければ CPU のプロセスになる。 |
| placement | 配置 | Where an instance runs: the FPGA where there is one (a backend that makes circuits, `mix ehls.compile`), else the CPU; `on: :cpu | :fpga` says it. / インスタンスが動く場所。FPGA があれば FPGA（回路を作るバックエンドや `mix ehls.compile`）、なければ CPU。`on: :cpu | :fpga` で指定もできる。 |
| stage | パイプラインの関数 | One function in an instance's pipe (`|>`): a `defhls` function (a kernel) or a block. / インスタンスの中でパイプ（`|>`）でつないだものの 1 つ。`defhls` の関数（カーネル）かブロック。 |
| link | リンク | The registered connection between two functions joined by the pipe, holding a few elements. / パイプでつないだ関数同士をつなぐレジスタ。数要素を持てる。 |
| element | 要素 | One value of a stream: a value up to 64 bits, or a tuple of them; it moves in one clock. / ストリームの 1 つの値。64 ビットまでの値か、そのタプル。1 クロックで動く。 |
| word | ワード | 32 bits: the CPU reads a state and writes a level in words, and the DMA moves words. / 32 ビット。CPU が状態を読み、レベルを書く単位で、DMA が運ぶ単位。 |
| tuple | タプル | Values born together. / 一緒に生まれた値の組。 |
| memory | メモリ | The FPGA's memory (block RAM) a tuple of a function's state is put in where it is placed with `transform(init, &f/2, memory: [:hist])`: smaller than registers, one element read or written per clock. / 関数の状態の中のタプルを、`transform(init, &f/2, memory: [:hist])` と置いたときに入れる FPGA のメモリ（ブロック RAM）。レジスタより小さいが、1 クロックに 1 か所ずつ読み書きする。 |
| agent | エージェント | One state for several lines of an instance, `EHLS.Agent`, as Elixir's `Agent`: its functions take it in turn, one element at a time. / インスタンスの複数の行で使う 1 つの状態。`EHLS.Agent`。Elixir の `Agent` と同じ書き方で、関数が 1 要素ずつ順番に状態を受け取る。 |
| level | レベル | A value of which only the latest matters; a register in the circuit, read by what is wired to it. / 最新の値だけが意味を持つもの。回路ではレジスタで、配線した先から読める。 |
| event | イベント | Something rare, each one mattering: in the FPGA the circuit of a stream (valid / ready), on the CPU one message each. / まれに起き、1 回ずつ大事なもの。FPGA の中ではストリームと同じ回路（valid と ready）、CPU では 1 回ごとのメッセージ。 |
| topic | トピック | The name (an atom) events go under: `EHLS.PubSub.broadcast(topic)` in an instance, `EHLS.PubSub.subscribe(topic)` on the CPU, as in `Phoenix.PubSub`. / イベントに付ける名前（アトム）。インスタンスの中の `EHLS.PubSub.broadcast(topic)` で出し、CPU の `EHLS.PubSub.subscribe(topic)` で受け取る。`Phoenix.PubSub` と同じ考え方。 |
| stream | ストリーム | Every element in order; has valid and ready in the circuit. / 全部の要素が順番どおりに届くもの。回路では valid と ready を持つ。 |
| source / sink | ソース / シンク | A block that only gives / only takes a stream. / ストリームを出すだけ、受け取るだけのブロック。 |
| back-pressure | バックプレッシャー | A full link stopping the functions before it in the pipe. / 埋まったリンクが、パイプの手前の関数を止めること。 |
| CPU end | CPU との端 | An instance's input or output towards the CPU, one DMA engine. / インスタンスの CPU 側の入力または出力。DMA エンジン 1 つ。 |
| instance of levels | レベルのインスタンス | A `definstance` whose arguments have types: the CPU writes them, the result is held, and a kernel can read it. Also "an instance of values". / 引数に型のある `definstance`。CPU が引数を書き、結果は保たれ、カーネルから読める。「値のインスタンス」とも言う。 |
| stream function | ストリーム関数 | A `defhls` taking a stream: a name for functions joined with the pipe; on the CPU a list in, a list out. / ストリームを受け取る `defhls`。パイプでつないだ関数に付けた名前。CPU ではリストを受け取ってリストを返す。 |
| join | 合流 | Two streams into one function, one element of each: `zip_with(a, b, &f/2)`. / 2 つのストリームを 1 つの関数に入れること。それぞれから 1 要素ずつ: `zip_with(a, b, &f/2)`。 |
| fork | 分岐 | A stream named and used twice: every element to each branch. / 名前を付けて 2 回使ったストリーム。要素はそれぞれの枝に渡る。 |
| wired | 配線 | An instance called inside another: its input and output connected there, no CPU ends. / ほかのインスタンスの中で呼んだインスタンスのつながり。その入出力はそこにつながり、CPU との端にはならない。 |
| block | ブロック | What can be placed in an instance without being written with `defhls`: a device or a built-in block. / `defhls` で書かずにインスタンスに置けるもの。デバイスか組み込みのブロック。 |
| device | デバイス | A stage with physical pins (`i2s_out`, `usb_bulk_in`, `sample`, ...), which the CPU cannot run. The device backend is another thing: the FPGA family. / 物理ピンを持つブロック（`i2s_out`、`usb_bulk_in`、`sample` など）。CPU では動かせない。デバイスのバックエンドは別のもので、FPGA の品種を指す。 |
| built-in block | 組み込みのブロック | A block without pins, tied to the circuit's time or the CPU (`ticks`, `hold`, `run`). / ピンのないブロック。回路の時間や CPU に関わる（`ticks`、`hold`、`run`）。 |
| block package | ブロックのパッケージ | What delivers devices: a module implementing `EHLS.Blocks`. / デバイスを配る単位。`EHLS.Blocks` を実装したモジュール。 |
| peripheral | 周辺回路 | A circuit used from the CPU, not placed in an instance (e.g. an LCD). / インスタンスに置かず、CPU から使う回路（液晶など）。 |
| backend | バックエンド | What depends on the hardware: device, SoC, runtime. / ハードウェアに依存する部分。デバイス、SoC、ランタイムの 3 種類。 |
| target | ターゲット | A board on top of a combination of backends. / バックエンドの組み合わせの上に載るボード。 |
| RTL boundary | RTL の境界 | What the core gives the backends: RTL and its description. / 本体がバックエンドに渡すもの。RTL とその説明。 |
