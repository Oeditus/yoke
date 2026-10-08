defmodule Yoke.Practices do
  @moduledoc """
  Manages system-global (~/.yoke/practices/<language>.lmml) and project-local
  (.yoke/practices/<language>.lmml) "Good Practices" for programming languages in .lmml format.

  When a project in a new language is first seen by yoke, it prompts the user to
  point to exemplary projects, walks through those, and squeezes out a human-editable
  list of good practices in .lmml format. These practices are merged between global
  and local sources and injected into prompt context whenever yoke works with code
  in that language.
  """
  require Logger

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.QuestionPrompt

  @language_indicators %{
    "elixir" => ["mix.exs", "*.ex", "*.exs"],
    "python" => ["pyproject.toml", "setup.py", "requirements.txt", "Pipfile", "*.py"],
    "rust" => ["Cargo.toml", "*.rs"],
    "typescript" => ["tsconfig.json", "*.ts", "*.tsx"],
    "javascript" => ["package.json", "*.js", "*.jsx"],
    "go" => ["go.mod", "*.go"],
    "c" => ["CMakeLists.txt", "Makefile", "*.c", "*.h"],
    "cpp" => ["CMakeLists.txt", "Makefile", "*.cpp", "*.hpp", "*.cc", "*.cxx"],
    "java" => ["pom.xml", "build.gradle", "*.java"],
    "kotlin" => ["build.gradle.kts", "*.kt"],
    "ruby" => ["Gemfile", "*.rb"],
    "php" => ["composer.json", "*.php"],
    "csharp" => ["*.csproj", "*.cs"],
    "swift" => ["Package.swift", "*.swift"],
    "zig" => ["build.zig", "*.zig"]
  }

  @default_practices %{
    "elixir" => [
      "Follow standard Mix project structure (`lib/`, `test/`, `config/`).",
      "Use pattern matching in function heads rather than complex conditional branching.",
      "Prefer the pipe operator `|>` for clear sequential data transformations.",
      "Document public modules and functions using `@moduledoc` and `@doc`.",
      "Keep functions small, pure, and explicit in error handling (`{:ok, result}` / `{:error, reason}`).",
      "Write unit tests with `ExUnit` covering edge cases and boundary conditions."
    ],
    "python" => [
      "Adhere to PEP 8 formatting guidelines and use type hints where feasible.",
      "Use explicit exception handling instead of bare `except:` clauses.",
      "Structure projects cleanly with virtual environments and standard dependency manifests (`pyproject.toml`).",
      "Write docstrings for modules, classes, and public functions.",
      "Prefer list/dict comprehensions over complex loops for readable data transformations."
    ],
    "rust" => [
      "Follow standard Cargo workspace layout (`src/main.rs` or `src/lib.rs`).",
      "Leverage Rust's type system (`Option`, `Result`) for robust error handling without unwrap in production.",
      "Keep scope of mutable borrows as narrow as possible.",
      "Write doc tests and unit tests in a nested `tests` module."
    ],
    "typescript" => [
      "Maintain strict type safety and avoid `any` wherever possible.",
      "Structure code into modular components with explicit interface declarations.",
      "Handle async promises with clear `try/catch` or typed error boundaries.",
      "Use consistent linting and formatting rules (ESLint, Prettier)."
    ],
    "javascript" => [
      "Use modern ES6+ syntax (`const`/`let`, arrow functions, destructuring).",
      "Keep functions small and single-purpose.",
      "Validate inputs at system boundaries and handle asynchronous errors gracefully."
    ],
    "go" => [
      "Follow standard Go project structure (`cmd/`, `pkg/`, `internal/`).",
      "Handle error return values explicitly immediately after call sites.",
      "Keep interfaces small and focused (prefer single-method interfaces where applicable)."
    ]
  }

  @doc "Returns the directory path for system-global practices (~/.yoke/practices)."
  def global_practices_dir(opts \\ []) do
    Keyword.get(opts, :global_dir) || Path.expand("~/.yoke/practices")
  end

  @doc "Returns the directory path for project-local practices (.yoke/practices)."
  def local_practices_dir(cwd \\ ".") do
    Path.join([cwd, ".yoke", "practices"])
  end

  @doc "Returns the path to global practice file for a language."
  def global_practice_path(language, opts \\ []) do
    Path.join(global_practices_dir(opts), "#{sanitize_language(language)}.lmml")
  end

  @doc "Returns the path to local practice file for a language."
  def local_practice_path(language, cwd \\ ".") do
    Path.join(local_practices_dir(cwd), "#{sanitize_language(language)}.lmml")
  end

  @doc "Sanitizes a language name to a safe filename slug."
  def sanitize_language(lang) when is_binary(lang) do
    lang
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^\w\-]/, "_")
  end

  def sanitize_language(lang), do: to_string(lang) |> sanitize_language()

  @doc "Detects project language(s) by inspecting files in `cwd`."
  def detect_languages(cwd \\ ".") do
    root_files =
      case File.ls(cwd) do
        {:ok, files} -> files
        _ -> []
      end

    detected =
      Enum.reduce(@language_indicators, [], fn {lang, indicators}, acc ->
        matches? =
          Enum.any?(indicators, fn ind ->
            if String.contains?(ind, "*") do
              ext = String.replace(ind, "*", "")

              Enum.any?(root_files, fn f ->
                String.ends_with?(f, ext) or
                  (File.dir?(Path.join(cwd, f)) and not hidden_or_build_dir?(f) and
                     has_extension_in_dir?(Path.join(cwd, f), ext))
              end)
            else
              ind in root_files
            end
          end)

        if matches?, do: [lang | acc], else: acc
      end)
      |> Enum.reverse()

    # Disambiguate typescript/javascript if both detected
    cond do
      "typescript" in detected and "javascript" in detected ->
        if File.exists?(Path.join(cwd, "tsconfig.json")) do
          Enum.reject(detected, &(&1 == "javascript"))
        else
          detected
        end

      detected == [] ->
        # Default fallback if no known indicator matches
        []

      true ->
        detected
    end
  end

  defp hidden_or_build_dir?(name) do
    String.starts_with?(name, ".") or
      name in ["_build", "deps", "node_modules", "target", "vendor", "dist", "build"]
  end

  defp has_extension_in_dir?(dir_path, ext) do
    case File.ls(dir_path) do
      {:ok, files} -> Enum.any?(files, &String.ends_with?(&1, ext))
      _ -> false
    end
  end

  @doc "Checks if practice file exists in global or local directory for language."
  def has_practices?(language, cwd \\ ".", opts \\ []) do
    g_path = global_practice_path(language, opts)
    l_path = local_practice_path(language, cwd)

    (File.exists?(g_path) and non_empty_file?(g_path)) or
      (File.exists?(l_path) and non_empty_file?(l_path))
  end

  defp non_empty_file?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > 10
      _ -> false
    end
  end

  @doc """
  Loads merged practices (global + project-local) for a given language.
  Returns map: `%{language: lang, items: [...], narrative: text, manifest: map}`.
  """
  def load_practices(language, cwd \\ ".", opts \\ []) do
    lang_slug = sanitize_language(language)
    g_path = global_practice_path(lang_slug, opts)
    l_path = local_practice_path(lang_slug, cwd)

    g_parsed = if File.exists?(g_path), do: parse_lmml_file(g_path), else: nil
    l_parsed = if File.exists?(l_path), do: parse_lmml_file(l_path), else: nil

    case {g_parsed, l_parsed} do
      {nil, nil} ->
        %{
          language: lang_slug,
          items: [],
          narrative: "",
          manifest: %{"language" => lang_slug},
          sources: []
        }

      {g, nil} ->
        g

      {nil, l} ->
        l

      {g, l} ->
        merged_items = Enum.uniq(g.items ++ l.items)
        merged_sources = Enum.uniq(g.sources ++ l.sources)

        merged_manifest =
          Map.merge(g.manifest, l.manifest)
          |> Map.put("sources", merged_sources)
          |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

        narrative = render_narrative(lang_slug, merged_items, merged_manifest)

        %{
          language: lang_slug,
          items: merged_items,
          narrative: narrative,
          manifest: merged_manifest,
          sources: merged_sources
        }
    end
  end

  @doc "Parses a .lmml practice file into items and manifest metadata."
  def parse_lmml_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_lmml_content(content, path)

      {:error, err} ->
        Logger.warning("[Practices] Failed to read #{path}: #{inspect(err)}")

        %{
          language: Path.basename(path, ".lmml"),
          items: [],
          narrative: "",
          manifest: %{},
          sources: []
        }
    end
  end

  @doc "Parses raw LMML string content."
  def parse_lmml_content(content, filename \\ "practice.lmml") when is_binary(content) do
    {narrative, manifest} =
      case Lmml.new_text(filename, content) do
        {:ok, bundle} ->
          narr = Lmml.narrative(bundle)

          man =
            case Lmml.manifest(bundle) do
              {:ok, %Lmml.Manifest{data: data}} when is_map(data) -> data
              _ -> extract_manifest_json(content)
            end

          {narr, man}

        _ ->
          {content, extract_manifest_json(content)}
      end

    items = extract_items_from_markdown(narrative)
    lang = Map.get(manifest, "language") || Path.basename(filename, ".lmml")
    sources = Map.get(manifest, "sources", [])

    %{
      language: lang,
      items: items,
      narrative: narrative,
      manifest: manifest,
      sources: sources
    }
  end

  defp extract_manifest_json(content) do
    case Regex.run(~r/@@@manifest\.json\s*\n(.*?)\n\s*@@@/s, content) do
      [_, json_str] ->
        case Yoke.Json.decode(json_str) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "Extracts practice list items from Markdown text."
  def extract_items_from_markdown(markdown) when is_binary(markdown) do
    # Remove @@@manifest.json block first
    clean_text = Regex.replace(~r/@@@manifest\.json.*?(@@@|$)/s, markdown, "")

    clean_text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line ->
      String.match?(line, ~r/^(\-|\*|\d+\.)\s+/)
    end)
    |> Enum.map(fn line ->
      Regex.replace(~r/^(\-|\*|\d+\.)\s+/, line, "") |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Saves practices for a language in .lmml format.
  Saves to both global (~/.yoke/practices/<lang>.lmml) and project-local (.yoke/practices/<lang>.lmml)
  by default, or as specified by `opts[:target]` (`:both`, `:global`, or `:local`).
  """
  def save_practices(language, items_or_narrative, opts \\ [], cwd \\ ".") do
    lang_slug = sanitize_language(language)
    target = Keyword.get(opts, :target, :both)
    sources = Keyword.get(opts, :sources, [])
    manifest_extra = Keyword.get(opts, :manifest, %{})

    items =
      cond do
        is_list(items_or_narrative) -> items_or_narrative
        is_binary(items_or_narrative) -> extract_items_from_markdown(items_or_narrative)
        true -> []
      end

    manifest =
      %{
        "language" => lang_slug,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "sources" => sources
      }
      |> Map.merge(manifest_extra)

    lmml_content = render_narrative(lang_slug, items, manifest)

    res_global =
      if target in [:both, :global] do
        g_path = global_practice_path(lang_slug, opts)
        g_path |> Path.dirname() |> File.mkdir_p!()
        File.write(g_path, lmml_content)
      else
        :ok
      end

    res_local =
      if target in [:both, :local] do
        l_path = local_practice_path(lang_slug, cwd)
        l_path |> Path.dirname() |> File.mkdir_p!()
        File.write(l_path, lmml_content)
      else
        :ok
      end

    case {res_global, res_local} do
      {:ok, :ok} -> {:ok, lmml_content}
      {{:error, err}, _} -> {:error, "Failed saving global practice: #{inspect(err)}"}
      {_, {:error, err}} -> {:error, "Failed saving local practice: #{inspect(err)}"}
    end
  end

  @doc "Renders a complete .lmml file payload."
  def render_narrative(language, items, manifest) do
    lang_title = String.capitalize(language)
    items_text = Enum.map_join(items, "\n", fn item -> "- #{item}" end)

    manifest_json = Yoke.Json.encode!(manifest, pretty: true)

    """
    # Good Practices for #{lang_title}

    The following good practices are maintained for projects using #{lang_title}. They are automatically injected into Yoke prompt context. You can edit this list directly or use `/practices` in Yoke REPL.

    #{items_text}

    @@@manifest.json
    #{manifest_json}
    @@@
    """
  end

  @doc """
  Squeezes good practices for `language` by walking through given `project_paths`
  and extracting key code conventions, architecture, and idioms.
  """
  def squeeze_practices(language, project_paths, opts \\ []) do
    lang_slug = sanitize_language(language)
    cwd = Keyword.get(opts, :cwd, ".")

    IO.puts(
      Formatter.format_info(
        "Walking through exemplary projects for '#{lang_slug}' at: #{Enum.join(project_paths, ", ")}…"
      )
    )

    code_samples = collect_exemplary_snippets(project_paths, lang_slug)

    items =
      if code_samples != "" and api_key_available?() do
        prompt = """
        You are an expert software architect in #{lang_slug}.
        Walk through the following exemplary project snippets and structure, and squeeze a concise list of 5-10 actionable, high-value "Good Practices" for writing clean, idiomatic, high-quality #{lang_slug} code in this ecosystem.

        Return ONLY bullet points starting with `- `, with no extra intro or conversational text.

        ### Exemplary Code Snippets & Structure:
        #{code_samples}
        """

        target_model =
          Keyword.get(opts, :model) ||
            System.get_env("DEEPSEEK_MODEL") ||
            Map.get(Yoke.Config.load_config(cwd), "model", "deepseek-chat")

        case Yoke.Client.DeepSeekAPI.chat_completion(
               [%{"role" => "user", "content" => prompt}],
               [],
               model: target_model,
               temperature: 0.3
             ) do
          {:ok, %{content: response_text}} ->
            extracted = extract_items_from_markdown(response_text)
            if extracted != [], do: extracted, else: default_practices_for(lang_slug)

          _ ->
            default_practices_for(lang_slug)
        end
      else
        default_practices_for(lang_slug)
      end

    save_opts = Keyword.merge(opts, sources: project_paths)
    save_practices(lang_slug, items, save_opts, cwd)
  end

  def default_practices_for(language) do
    lang_slug = sanitize_language(language)

    Map.get(@default_practices, lang_slug) ||
      [
        "Follow clean modular code organization and clear naming conventions for #{lang_slug}.",
        "Keep functions small, single-purpose, and easy to test.",
        "Write clear inline documentation and public API comments.",
        "Handle potential runtime errors explicitly at boundaries."
      ]
  end

  defp collect_exemplary_snippets(paths, language) do
    Enum.map_join(paths, "\n\n", fn path ->
      expanded = Path.expand(path)

      if File.dir?(expanded) do
        files = find_relevant_files(expanded, language)

        snippets =
          files
          |> Enum.take(12)
          |> Enum.map_join("\n\n", fn file_path ->
            rel_path = Path.relative_to(file_path, expanded)

            case File.read(file_path) do
              {:ok, content} ->
                truncated = content |> String.split("\n") |> Enum.take(60) |> Enum.join("\n")
                "--- File: #{rel_path} ---\n#{truncated}"

              _ ->
                ""
            end
          end)

        "=== Project Path: #{expanded} ===\n#{snippets}"
      else
        ""
      end
    end)
  end

  defp find_relevant_files(dir, language) do
    indicators = Map.get(@language_indicators, language, ["*"])

    case File.ls(dir) do
      {:ok, root_items} ->
        # Find matches in root and subdirectories like lib, src, config
        top_dirs = ["lib", "src", "app", "pkg", "cmd", "config", "test", "tests"]

        candidate_dirs =
          [dir] ++
            (root_items
             |> Enum.filter(&(&1 in top_dirs and File.dir?(Path.join(dir, &1))))
             |> Enum.map(&Path.join(dir, &1)))

        candidate_dirs
        |> Enum.flat_map(fn d ->
          case File.ls(d) do
            {:ok, files} ->
              files
              |> Enum.reject(&hidden_or_build_dir?/1)
              |> Enum.map(&Path.join(d, &1))
              |> Enum.filter(fn f ->
                File.regular?(f) and
                  Enum.any?(indicators, fn ind ->
                    ext = String.replace(ind, "*", "")
                    String.ends_with?(f, ext) or String.ends_with?(f, ind)
                  end)
              end)

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp api_key_available? do
    System.get_env("DEEPSEEK_API_KEY") != nil and System.get_env("DEEPSEEK_API_KEY") != ""
  end

  @doc """
  Ensures that practices are set up for all languages in `cwd`.
  If a project language is first seen (no practices exist yet in ~/.yoke or .yoke):
    - Asks the user to point to exemplary project paths.
    - Squeezes practices from those projects (or uses defaults if skipped).
    - Saves practices to global and project-local .yoke directories.
  """
  def ensure_practices_for_workspace(cwd \\ ".", opts \\ []) do
    languages = detect_languages(cwd)
    interactive? = Keyword.get(opts, :interactive, true) and tty_interactive?()

    Enum.each(languages, fn lang ->
      unless has_practices?(lang, cwd) do
        paths =
          if interactive? and not Yoke.Config.god_mode?() do
            question =
              "Language '#{lang}' is new to yoke. Please enter path(s) to exemplary #{lang} project(s) to learn good practices from (or hit Enter for standard defaults):"

            ans =
              QuestionPrompt.do_ask_single_question(
                question,
                ["Hit Enter for defaults (Recommended)"],
                false,
                true,
                []
              )

            case ans do
              %{custom: custom_val} when is_binary(custom_val) and custom_val != "" ->
                custom_val
                |> String.split(~r/[,;\s]+/, trim: true)

              _ ->
                []
            end
          else
            []
          end

        if paths != [] do
          squeeze_practices(lang, paths, cwd: cwd)
        else
          IO.puts(Formatter.format_info("Generating baseline good practices for '#{lang}'…"))

          save_practices(lang, default_practices_for(lang), [sources: ["default_baseline"]], cwd)
        end

        g_p = global_practice_path(lang)
        l_p = local_practice_path(lang, cwd)

        IO.puts(
          Formatter.format_success(
            "Good practices for '#{lang}' saved to:\n  - Global: #{g_p}\n  - Project: #{l_p}\nYou can edit these files or use `/practices` to view/modify them."
          )
        )
      end
    end)
  end

  defp tty_interactive? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      false
    else
      case :io.columns(:user) do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  @doc "Builds prompt preamble text containing language good practices for `cwd`."
  def build_preamble(cwd \\ ".") do
    languages = detect_languages(cwd)

    practices_blocks =
      languages
      |> Enum.map(&load_practices(&1, cwd))
      |> Enum.reject(fn p -> Enum.empty?(p.items) end)

    if Enum.empty?(practices_blocks) do
      ""
    else
      block_text =
        Enum.map_join(practices_blocks, "\n\n", fn p ->
          lang_title = String.capitalize(p.language)
          items_text = Enum.map_join(p.items, "\n", fn item -> "- #{item}" end)
          "### Good Practices for #{lang_title}\n#{items_text}"
        end)

      "=== Language Good Practices ===\n\n#{block_text}\n\n===============================\n"
    end
  end

  @doc "Adds a new practice item for a language and saves globally & locally."
  def add_practice(language, practice_text, cwd \\ ".", opts \\ []) do
    lang_slug = sanitize_language(language)
    text = String.trim(practice_text)

    if text == "" do
      {:error, "Practice text cannot be empty."}
    else
      current = load_practices(lang_slug, cwd, opts)
      updated_items = Enum.uniq(current.items ++ [text])
      save_opts = Keyword.merge(opts, sources: current.sources)
      save_practices(lang_slug, updated_items, save_opts, cwd)
      {:ok, text}
    end
  end

  @doc "Deletes practice items at given 1-based indices or exact matching text."
  def delete_practices(language, indices_or_texts, cwd \\ ".", opts \\ [])
      when is_list(indices_or_texts) do
    lang_slug = sanitize_language(language)
    current = load_practices(lang_slug, cwd, opts)

    to_remove =
      Enum.reduce(indices_or_texts, MapSet.new(), fn item, acc ->
        cond do
          is_integer(item) ->
            MapSet.put(acc, item)

          is_binary(item) ->
            case Integer.parse(String.trim(item)) do
              {idx, ""} -> MapSet.put(acc, idx)
              _ -> MapSet.put(acc, String.trim(item))
            end

          true ->
            acc
        end
      end)

    updated_items =
      current.items
      |> Enum.with_index(1)
      |> Enum.reject(fn {text, idx} ->
        MapSet.member?(to_remove, idx) or MapSet.member?(to_remove, text)
      end)
      |> Enum.map(fn {text, _idx} -> text end)

    save_opts = Keyword.merge(opts, sources: current.sources)
    save_practices(lang_slug, updated_items, save_opts, cwd)
    {:ok, updated_items}
  end
end
