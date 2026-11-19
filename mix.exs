defmodule ElixirHLS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-hls/elixir-hls"

  def project do
    [
      app: :elixir_hls,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      name: "Elixir HLS",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package(),
      description: "High-level synthesis from Elixir: defhls / definstance -> MLIR -> CIRCT -> SystemVerilog",
      test_paths: ["test"],
      elixirc_paths: ["lib"]
    ]
  end

  def application, do: [extra_applications: []]

  defp deps do
    [{:ex_doc, "~> 0.38", only: :dev, runtime: false}]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv docs mix.exs README.md README.ja.md LICENSE),
      exclude_patterns: [~r/__pycache__/, ~r/\.pyc$/]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      assets: %{"docs/images" => "images"},
      extras: [
        "README.md": [title: "Overview"],
        "docs/getting_started.md": [title: "Getting started"],
        "docs/concepts.md": [title: "How Elixir HLS works"],
        "docs/glossary.md": [title: "Glossary / 用語集"],
        "docs/vision.md": [title: "Vision"],
        "docs/design.md": [title: "Design"],
        "README.ja.md": [title: "概要", filename: "readme-ja"],
        "docs/getting_started.ja.md": [title: "はじめに", filename: "getting_started-ja"],
        "docs/concepts.ja.md": [title: "Elixir HLS の考え方", filename: "concepts-ja"],
        "docs/vision.ja.md": [title: "構想", filename: "vision-ja"],
        "docs/design.ja.md": [title: "設計", filename: "design-ja"],
        "LICENSE": [title: "License"]
      ],
      groups_for_extras: [
        Guides: ~r{^(README|docs/(getting_started|concepts|glossary|vision|design))\.md$},
        "ガイド（日本語）": ~r{\.ja\.md$}
      ],
      groups_for_modules: [
        "Writing circuits": [EHLS, EHLS.Pipeline, EHLS.Stream, EHLS.Agent, EHLS.PubSub, EHLS.GPIO, EHLS.Server],
        Blocks: [EHLS.Blocks, EHLS.SoC.LiteX.Blocks],
        Backends: [
          EHLS.Backend,
          EHLS.Device,
          EHLS.Device.Generic,
          EHLS.Device.GowinGW5A,
          EHLS.SoC,
          EHLS.SoC.LiteX,
          EHLS.Runtime,
          EHLS.Runtime.AtomVM
        ],
        Internals: [EHLS.MLIR, EHLS.NIF],
        "Mix tasks": [~r/^Mix\.Tasks\./]
      ]
    ]
  end
end
