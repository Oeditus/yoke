defmodule Yoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :yoke,
      version: "0.21.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      test_ignore_filters: [~r{test/support/}],
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
      # NOTE: `app:` is deliberately omitted. Setting it makes the escript
      # start the `:yoke` application *before* `Yoke.CLI.Main.main/1` runs,
      # so every startup log line is emitted before `main/0` can install
      # `Yoke.CLI.LogFormatter` or prime `Yoke.CLI.Output` -- producing ~19
      # lines of raw `[info]`/`[debug]` output with timestamps in front of
      # the actual command output. `main/0` calls
      # `Application.ensure_all_started(:yoke)` itself, after both seams are
      # installed.
      escript: [
        main_module: Yoke.CLI.Main,
        name: "yoke_escript"
      ],
      deps: deps()
    ] ++ native_test_build_config()
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
      md_dep(),
      {:lmml, "~> 0.2"},
      {:makeup_elixir, ">= 0.0.0", optional: true},
      {:makeup_erlang, ">= 0.0.0", optional: true},
      {:makeup_cure, ">= 0.0.0", optional: true},
      {:makeup_patch, ">= 0.0.0", optional: true},
      {:makeup_lmml, ">= 0.0.0", optional: true},
      {:makeup_eex, ">= 0.0.0", optional: true},
      {:makeup_json, ">= 0.0.0", optional: true},
      {:makeup_rust, ">= 0.0.0", optional: true},
      {:makeup_html, ">= 0.0.0", optional: true},
      {:owl, "~> 0.13"},
      ragex_dep(),
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

  # Opt-in source override for validating fixes before an Md Hex release.
  defp md_dep do
    case System.get_env("LOCAL_MD") do
      nil -> {:md, "~> 0.13", override: true}
      path -> {:md, path: Path.expand(path), override: true}
    end
  end

  # Opt-in source override for validating changes before a Ragex Hex release.
  defp ragex_dep do
    case System.get_env("LOCAL_RAGEX") do
      nil -> {:ragex, "~> 0.39"}
      path -> {:ragex, path: Path.expand(path), override: true}
    end
  end

  # `ragex`'s Bumblebee-based embeddings/vector search and Image processing
  # tools rely on native/NIF-backed libraries (exla, image/vix) that cannot
  # load from inside a `mix escript.build` archive (see MIX_ENV=:escript
  # below). ragex itself marks them `optional: true`, so this project must
  # declare them directly to pull them into the standard `mix release` /
  # dev dependency tree and keep embeddings-based semantic search and image
  # tools working there. Ordinary tests omit this optional native stack:
  # Nx.BinaryBackend does not prevent EXLA's application/NIF from starting.
  # Opt in with YOKE_EMBEDDINGS=true mix test on a suitably configured host.
  # Escript builds always omit native dependencies, regardless of the flag.
  defp embeddings_deps do
    if Mix.env() == :escript or
         (Mix.env() == :test and System.get_env("YOKE_EMBEDDINGS") not in ["1", "true"]) do
      []
    else
      [
        {:bumblebee, "~> 0.5"},
        {:nx, "~> 1.0", override: true},
        {:exla, "~> 1.0", override: true},
        # EXLA 1.0 uses Decoder.decode; Fine 0.2 requires Decoder.try_decode.
        # Keep the 0.1 API even when updating all dependencies.
        {:fine, "~> 0.1.6", runtime: false},
        {:image, "~> 0.54"}
      ]
    end
  end

  # Mix can reuse .app files when only environment-controlled deps change.
  # Keep opt-in native tests out of the ordinary test artifact directory.
  defp native_test_build_config do
    if Mix.env() == :test and System.get_env("YOKE_EMBEDDINGS") in ["1", "true"] do
      [
        build_path: Path.join(System.get_env("MIX_BUILD_ROOT", "_build"), "test_native"),
        build_per_environment: false
      ]
    else
      []
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
