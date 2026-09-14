defmodule Yoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :yoke,
      version: "0.13.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      releases: [
        yoke: [
          include_executables_for: [:unix],
          applications: [yoke: :permanent],
          steps: [:assemble]
        ]
      ],
      # NOTE: intentionally NOT named "yoke" -- `mix escript.build` writes its
      # output to a file at the project root with this name, which would
      # silently overwrite the tracked `yoke` launcher bash script (same
      # filename). The release workflow renames the built escript to `yoke`
      # only when packaging the release asset, after the checkout is done.
      escript: [
        main_module: Yoke.CLI.Main,
        name: "yoke_escript",
        app: :yoke
      ],
      deps: deps()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {Yoke.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7"},
      {:marcli, "~> 0.3"},
      {:md, "~> 0.13", override: true},
      {:lmml, "~> 0.2"},
      {:makeup_elixir, ">= 0.0.0", optional: true},
      {:makeup_erlang, ">= 0.0.0", optional: true},
      {:makeup_cure, ">= 0.0.0", optional: true},
      {:makeup_patch, ">= 0.0.0", optional: true},
      {:makeup_eex, ">= 0.0.0", optional: true},
      {:makeup_json, ">= 0.0.0", optional: true},
      {:makeup_rust, ">= 0.0.0", optional: true},
      {:makeup_html, ">= 0.0.0", optional: true},
      {:owl, "~> 0.13"},
      {:ragex, "~> 0.30"},
      {:dllb, "~> 0.9"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:oeditus_credo, "~> 0.11", only: [:dev, :test], runtime: false},
      {:propwise, "~> 0.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      # Scans mix.lock for known security vulnerabilities (`mix deps.audit`)
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ] ++ embeddings_deps()
  end

  # `ragex`'s Bumblebee-based embeddings/vector search and Image processing
  # tools rely on native/NIF-backed libraries (exla, image/vix) that cannot
  # load from inside a `mix escript.build` archive (see MIX_ENV=:escript
  # below). ragex itself marks them `optional: true`, so this project must
  # declare them directly to pull them into the standard `mix release` /
  # dev / test dependency tree and keep embeddings-based semantic search and
  # image tools working there. They're deliberately omitted under the
  # dedicated `escript` Mix env used to build the standalone `yoke` escript,
  # so that build stays free of anything that can't load from an archive.
  defp embeddings_deps do
    if Mix.env() == :escript do
      []
    else
      [
        {:bumblebee, "~> 0.5"},
        {:nx, "~> 0.12"},
        {:exla, "~> 0.9"},
        {:image, "~> 0.54"}
      ]
    end
  end

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer", "deps.audit"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "deps.audit"
      ]
    ]
  end
end
