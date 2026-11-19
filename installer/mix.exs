defmodule EHLS.New.MixProject do
  use Mix.Project

  # The generator of a new application (mix ehls.new), an archive of its own with no dependencies: it is
  # installed and run before the application, and elixir-hls with it, exist.
  def project do
    [
      app: :ehls_new,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [],
      description: "mix ehls.new: the generator of a new Elixir HLS application (mix archive.install hex ehls_new)",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/elixir-hls/elixir-hls"},
        files: ~w(lib mix.exs LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:eex]]
end
