defmodule Yoke.Audit.Profiles do
  @moduledoc """
  Language-specific and project-configurable profiles for `Yoke.Audit`.

  Combines built-in ecosystem defaults (source/test globs, inline test
  patterns, sibling test path mappings, formatters, linters, typecheckers,
  lockfiles, and quality gates) with per-project overrides from
  `.yoke/config.json` under the `"audit"` key.
  """

  @default_ignore_dirs ~w(deps _build node_modules .git .elixir_ls target build dist .yoke tmp .venv venv __pycache__)

  @default_lockfiles ~w(
    mix.lock Cargo.lock package-lock.json pnpm-lock.yaml yarn.lock
    bun.lock bun.lockb poetry.lock uv.lock Pipfile.lock go.sum Gemfile.lock
  )

  @task_runner_files ~w(justfile Justfile Makefile Taskfile.yml)

  @profiles %{
    "elixir" => %{
      source_globs: ["lib/**/*.ex", "apps/*/lib/**/*.ex"],
      test_globs: ["test/**/*.exs", "test/**/*.ex", "apps/*/test/**/*.exs"],
      test_mapping: :elixir,
      inline_test_regex: nil,
      tools: [
        %{key: :formatter, label: "Formatter", files: [".formatter.exs"], builtin: false},
        %{key: :linter, label: "Credo", files: [".credo.exs", ".credo.ex"], builtin: false},
        %{
          key: :static_analysis,
          label: "Dialyzer",
          files: [".dialyzer_ignore.exs", "dialyzer.ignore-warnings"],
          builtin: false
        }
      ],
      lockfiles: ["mix.lock"],
      gate_detector: :mix_aliases
    },
    "rust" => %{
      source_globs: ["src/**/*.rs", "crates/*/src/**/*.rs", "examples/**/*.rs", "benches/**/*.rs"],
      test_globs: ["tests/**/*.rs", "crates/*/tests/**/*.rs"],
      test_mapping: nil,
      inline_test_regex: ~r/#\[cfg\(test\)\]/,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (rustfmt)",
          files: ["rustfmt.toml", ".rustfmt.toml"],
          builtin: true
        },
        %{
          key: :linter,
          label: "Linter (clippy)",
          files: ["clippy.toml", ".clippy.toml"],
          builtin: true
        }
      ],
      lockfiles: ["Cargo.lock"],
      gate_detector: :rust_gates
    },
    "go" => %{
      source_globs: ["**/*.go"],
      test_globs: ["**/*_test.go"],
      test_mapping: :go,
      inline_test_regex: nil,
      tools: [
        %{key: :formatter, label: "Formatter (gofmt)", files: [], builtin: true},
        %{
          key: :linter,
          label: "Linter (golangci-lint)",
          files: [".golangci.yml", ".golangci.yaml", ".golangci.toml", ".golangci.json"],
          builtin: false
        }
      ],
      lockfiles: ["go.sum"],
      gate_detector: :task_runners
    },
    "python" => %{
      source_globs: ["src/**/*.py", "app/**/*.py", "**/*.py"],
      test_globs: ["tests/**/*.py", "test/**/*.py", "**/test_*.py", "**/*_test.py"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (ruff/black)",
          files: ["ruff.toml", ".ruff.toml", "pyproject.toml"],
          builtin: false
        },
        %{
          key: :linter,
          label: "Linter (ruff/flake8)",
          files: ["ruff.toml", ".ruff.toml", ".flake8", "pyproject.toml"],
          builtin: false
        },
        %{
          key: :typechecker,
          label: "Typechecker (mypy/pyright)",
          files: ["mypy.ini", ".mypy.ini", "pyrightconfig.json", "pyproject.toml"],
          builtin: false
        }
      ],
      lockfiles: ["poetry.lock", "uv.lock", "Pipfile.lock", "pdm.lock", "requirements.txt"],
      gate_detector: :task_runners
    },
    "typescript" => %{
      source_globs: [
        "src/**/*.ts",
        "src/**/*.tsx",
        "lib/**/*.ts",
        "lib/**/*.tsx",
        "app/**/*.ts",
        "app/**/*.tsx"
      ],
      test_globs: [
        "**/*.test.ts",
        "**/*.test.tsx",
        "**/*.spec.ts",
        "**/*.spec.tsx",
        "test/**/*",
        "tests/**/*",
        "__tests__/**/*"
      ],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (prettier/biome)",
          files: [
            ".prettierrc",
            ".prettierrc.json",
            ".prettierrc.js",
            ".prettierrc.yml",
            "biome.json",
            "biome.jsonc"
          ],
          builtin: false
        },
        %{
          key: :linter,
          label: "Linter (eslint/biome)",
          files: [
            "eslint.config.js",
            "eslint.config.mjs",
            "eslint.config.ts",
            ".eslintrc.json",
            ".eslintrc.js",
            ".eslintrc.yml",
            "biome.json",
            "biome.jsonc"
          ],
          builtin: false
        },
        %{key: :typechecker, label: "TypeScript", files: ["tsconfig.json"], builtin: false}
      ],
      lockfiles: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"],
      gate_detector: :package_json_scripts
    },
    "javascript" => %{
      source_globs: [
        "src/**/*.js",
        "src/**/*.jsx",
        "lib/**/*.js",
        "lib/**/*.jsx",
        "app/**/*.js",
        "app/**/*.jsx"
      ],
      test_globs: [
        "**/*.test.js",
        "**/*.test.jsx",
        "**/*.spec.js",
        "**/*.spec.jsx",
        "test/**/*",
        "tests/**/*",
        "__tests__/**/*"
      ],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (prettier/biome)",
          files: [
            ".prettierrc",
            ".prettierrc.json",
            ".prettierrc.js",
            ".prettierrc.yml",
            "biome.json",
            "biome.jsonc"
          ],
          builtin: false
        },
        %{
          key: :linter,
          label: "Linter (eslint/biome)",
          files: [
            "eslint.config.js",
            "eslint.config.mjs",
            "eslint.config.ts",
            ".eslintrc.json",
            ".eslintrc.js",
            ".eslintrc.yml",
            "biome.json",
            "biome.jsonc"
          ],
          builtin: false
        }
      ],
      lockfiles: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"],
      gate_detector: :package_json_scripts
    },
    "ruby" => %{
      source_globs: ["lib/**/*.rb", "app/**/*.rb"],
      test_globs: ["spec/**/*_spec.rb", "test/**/*_test.rb"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{key: :linter, label: "Linter (rubocop)", files: [".rubocop.yml"], builtin: false}
      ],
      lockfiles: ["Gemfile.lock"],
      gate_detector: :task_runners
    },
    "java" => %{
      source_globs: ["src/main/**/*.java"],
      test_globs: ["src/test/**/*.java"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :linter,
          label: "Linter (checkstyle)",
          files: ["checkstyle.xml", "config/checkstyle/checkstyle.xml"],
          builtin: false
        }
      ],
      lockfiles: ["gradle.lockfile", "pom.xml"],
      gate_detector: :task_runners
    },
    "kotlin" => %{
      source_globs: ["src/main/**/*.kt"],
      test_globs: ["src/test/**/*.kt"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :linter,
          label: "Linter (detekt)",
          files: ["detekt.yml", ".detekt.yml"],
          builtin: false
        }
      ],
      lockfiles: ["gradle.lockfile"],
      gate_detector: :task_runners
    },
    "c" => %{
      source_globs: ["src/**/*.c", "src/**/*.h", "include/**/*.h"],
      test_globs: ["tests/**/*.c", "test/**/*.c"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (clang-format)",
          files: [".clang-format"],
          builtin: false
        },
        %{key: :linter, label: "Linter (clang-tidy)", files: [".clang-tidy"], builtin: false}
      ],
      lockfiles: ["CMakeLists.txt", "meson.build"],
      gate_detector: :task_runners
    },
    "cpp" => %{
      source_globs: ["src/**/*.cpp", "src/**/*.hpp", "src/**/*.cc", "include/**/*.hpp"],
      test_globs: ["tests/**/*.cpp", "test/**/*.cpp"],
      test_mapping: nil,
      inline_test_regex: nil,
      tools: [
        %{
          key: :formatter,
          label: "Formatter (clang-format)",
          files: [".clang-format"],
          builtin: false
        },
        %{key: :linter, label: "Linter (clang-tidy)", files: [".clang-tidy"], builtin: false}
      ],
      lockfiles: ["CMakeLists.txt", "meson.build"],
      gate_detector: :task_runners
    }
  }

  @fallback_profile %{
    source_globs: ["lib/**/*", "src/**/*", "app/**/*"],
    test_globs: ["test/**/*", "tests/**/*", "spec/**/*"],
    test_mapping: nil,
    inline_test_regex: nil,
    tools: [],
    lockfiles: @default_lockfiles,
    gate_detector: :task_runners
  }

  @doc """
  Resolves the effective audit profile for `cwd`, merging detected language
  profiles with any `"audit"` configuration in `.yoke/config.json` (or `opts`).
  """
  @spec resolve(String.t(), [String.t()], keyword()) :: map()
  def resolve(cwd, detected_languages, opts \\ []) do
    audit_cfg = load_audit_config(cwd, opts)

    languages =
      case Map.get(audit_cfg, "languages") do
        list when is_list(list) and list != [] -> list
        _ -> detected_languages
      end

    base = merge_language_profiles(languages)

    base
    |> Map.put(:languages, languages)
    |> apply_config_overrides(audit_cfg)
  end

  @doc """
  Detects configured quality gates for `cwd` according to the resolved profile.
  """
  @spec detect_quality_gates(String.t(), map()) :: [String.t()]
  def detect_quality_gates(cwd, profile) do
    custom_files = Map.get(profile, :custom_gate_files, [])

    detector_gates =
      profile
      |> Map.get(:gate_detectors, [:task_runners])
      |> Enum.flat_map(&run_gate_detector(cwd, &1))

    custom_found =
      custom_files
      |> Enum.filter(&File.exists?(Path.join(cwd, &1)))

    (detector_gates ++ custom_found)
    |> Enum.uniq()
  end

  @doc """
  Maps a relative source path to its expected sibling test path, or `nil` when
  no sibling test mapping applies.
  """
  @spec expected_test_path(String.t(), atom()) :: String.t() | nil
  def expected_test_path(relative_path, :elixir) do
    if String.ends_with?(relative_path, ".ex") do
      relative_path
      |> String.replace_prefix("lib/", "test/")
      |> String.replace_suffix(".ex", "_test.exs")
    end
  end

  def expected_test_path(relative_path, :go) do
    if String.ends_with?(relative_path, ".go") and
         not String.ends_with?(relative_path, "_test.go") do
      String.replace_suffix(relative_path, ".go", "_test.go")
    end
  end

  def expected_test_path(_relative_path, _mapping), do: nil

  # ---------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------

  defp load_audit_config(cwd, opts) do
    file_cfg =
      case Keyword.get(opts, :audit_config) do
        map when is_map(map) ->
          map

        _ ->
          cwd
          |> Yoke.Config.load_config()
          |> Map.get("audit", %{})
      end

    if is_map(file_cfg), do: file_cfg, else: %{}
  rescue
    _ -> %{}
  end

  defp merge_language_profiles([]) do
    Map.merge(@fallback_profile, %{
      ignore_dirs: @default_ignore_dirs,
      inline_test_regexes: [],
      test_mappings: [],
      gate_detectors: [:task_runners],
      custom_gate_files: []
    })
  end

  defp merge_language_profiles(languages) do
    profiles =
      languages
      |> Enum.map(&Map.get(@profiles, &1, @fallback_profile))

    %{
      source_globs: profiles |> Enum.flat_map(& &1.source_globs) |> Enum.uniq(),
      test_globs: profiles |> Enum.flat_map(& &1.test_globs) |> Enum.uniq(),
      test_mappings:
        profiles |> Enum.map(& &1.test_mapping) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      inline_test_regexes:
        profiles |> Enum.map(& &1.inline_test_regex) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      tools: merge_tools(profiles),
      lockfiles: profiles |> Enum.flat_map(& &1.lockfiles) |> Enum.uniq(),
      gate_detectors: profiles |> Enum.map(& &1.gate_detector) |> Enum.uniq(),
      ignore_dirs: @default_ignore_dirs,
      custom_gate_files: []
    }
  end

  defp merge_tools(profiles) do
    profiles
    |> Enum.flat_map(& &1.tools)
    |> Enum.uniq_by(&{&1.key, &1.label})
  end

  defp apply_config_overrides(profile, cfg) do
    profile
    |> override_list(:source_globs, cfg["source_globs"])
    |> override_list(:test_globs, cfg["test_globs"])
    |> extend_list(:ignore_dirs, cfg["ignore_dirs"])
    |> override_inline_regex(cfg["inline_test_regex"])
    |> override_hygiene(cfg["hygiene"])
  end

  defp override_list(profile, key, value) when is_list(value) and value != [] do
    Map.put(profile, key, Enum.filter(value, &is_binary/1))
  end

  defp override_list(profile, _key, _value), do: profile

  defp extend_list(profile, key, value) when is_list(value) do
    extra = Enum.filter(value, &is_binary/1)
    Map.update!(profile, key, &Enum.uniq(&1 ++ extra))
  end

  defp extend_list(profile, _key, _value), do: profile

  defp override_inline_regex(profile, pattern) when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, regex} -> Map.put(profile, :inline_test_regexes, [regex])
      _ -> profile
    end
  end

  defp override_inline_regex(profile, _), do: profile

  defp override_hygiene(profile, hygiene_cfg) when is_map(hygiene_cfg) do
    profile
    |> maybe_override_lockfiles(hygiene_cfg["lockfiles"])
    |> maybe_override_gates(hygiene_cfg["quality_gates"])
    |> maybe_override_tools(Map.drop(hygiene_cfg, ["lockfiles", "quality_gates"]))
  end

  defp override_hygiene(profile, _), do: profile

  defp maybe_override_lockfiles(profile, files) when is_list(files) do
    Map.put(profile, :lockfiles, Enum.filter(files, &is_binary/1))
  end

  defp maybe_override_lockfiles(profile, _), do: profile

  defp maybe_override_gates(profile, files) when is_list(files) do
    Map.put(profile, :custom_gate_files, Enum.filter(files, &is_binary/1))
  end

  defp maybe_override_gates(profile, _), do: profile

  defp maybe_override_tools(profile, tool_map) when map_size(tool_map) == 0, do: profile

  defp maybe_override_tools(profile, tool_map) do
    overrides =
      for {name, files} <- tool_map, is_binary(name) and is_list(files) do
        %{
          key: normalize_tool_key(name),
          label: String.capitalize(name),
          files: Enum.filter(files, &is_binary/1),
          builtin: false
        }
      end

    Map.update!(profile, :tools, fn existing ->
      override_keys = MapSet.new(overrides, & &1.key)
      kept = Enum.reject(existing, &MapSet.member?(override_keys, &1.key))
      kept ++ overrides
    end)
  end

  defp normalize_tool_key("formatter"), do: :formatter
  defp normalize_tool_key("linter"), do: :linter
  defp normalize_tool_key("typechecker"), do: :typechecker
  defp normalize_tool_key("static_analysis"), do: :static_analysis
  defp normalize_tool_key(other), do: other

  # ---------------------------------------------------------------------
  # Quality gate detectors
  # ---------------------------------------------------------------------

  defp run_gate_detector(cwd, :mix_aliases) do
    case File.read(Path.join(cwd, "mix.exs")) do
      {:ok, content} ->
        for name <- ["quality", "quality.ci"],
            String.contains?(content, ["\"#{name}\"", "#{name}:"]),
            do: name

      _ ->
        []
    end
  end

  defp run_gate_detector(cwd, :rust_gates) do
    cargo_lints =
      case File.read(Path.join(cwd, "Cargo.toml")) do
        {:ok, content} ->
          if String.contains?(content, ["[lints", "[workspace.lints"]),
            do: ["Cargo.toml [lints]"],
            else: []

        _ ->
          []
      end

    cargo_lints ++ run_gate_detector(cwd, :task_runners)
  end

  defp run_gate_detector(cwd, :package_json_scripts) do
    scripts =
      case File.read(Path.join(cwd, "package.json")) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, %{"scripts" => map}} when is_map(map) ->
              for key <- ["lint", "format", "typecheck", "check", "test"],
                  Map.has_key?(map, key),
                  do: "npm:#{key}"

            _ ->
              []
          end

        _ ->
          []
      end

    scripts ++ run_gate_detector(cwd, :task_runners)
  end

  defp run_gate_detector(cwd, :task_runners) do
    Enum.filter(@task_runner_files, &File.exists?(Path.join(cwd, &1)))
  end
end
