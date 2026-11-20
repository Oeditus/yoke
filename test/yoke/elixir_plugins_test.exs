defmodule Yoke.ElixirPluginsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Audit
  alias Yoke.CLI.CI
  alias Yoke.ElixirPlugins
  alias Yoke.PRReview

  setup %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib/demo"))
    File.mkdir_p!(Path.join(dir, "test/demo"))
    File.mkdir_p!(Path.join(dir, "deps/oeditus_credo"))
    File.mkdir_p!(Path.join(dir, "deps/propwise"))
    File.mkdir_p!(Path.join(dir, "deps/credo"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: [app: :demo, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(dir, "lib/demo/calc.ex"), """
    defmodule Demo.Calc do
      def add(a, b), do: a + b
    end
    """)

    File.write!(Path.join(dir, "test/demo/calc_test.exs"), """
    defmodule Demo.CalcTest do
      use ExUnit.Case
    end
    """)

    prev_env = System.get_env("YOKE_ELIXIR_PLUGINS")

    on_exit(fn ->
      if prev_env,
        do: System.put_env("YOKE_ELIXIR_PLUGINS", prev_env),
        else: System.delete_env("YOKE_ELIXIR_PLUGINS")
    end)

    {:ok, dir: dir}
  end

  describe "elixir_project?/1 and available_plugins/1" do
    test "detects mix.exs and installed deps", %{dir: dir} do
      assert ElixirPlugins.elixir_project?(dir)
      assert ElixirPlugins.available_plugins(dir) == ["oeditus_credo", "propwise", "credo"]

      non_elixir = Path.join(dir, "other")
      File.mkdir_p!(non_elixir)
      refute ElixirPlugins.elixir_project?(non_elixir)
      assert ElixirPlugins.available_plugins(non_elixir) == []
    end
  end

  describe "enabled?/2 opt-out" do
    test "defaults to true and respects opts, env, and config", %{dir: dir} do
      System.delete_env("YOKE_ELIXIR_PLUGINS")
      assert ElixirPlugins.enabled?(dir)
      refute ElixirPlugins.enabled?(dir, elixir_plugins: false)

      System.put_env("YOKE_ELIXIR_PLUGINS", "false")
      refute ElixirPlugins.enabled?(dir)
      assert ElixirPlugins.enabled?(dir, elixir_plugins: true)

      System.delete_env("YOKE_ELIXIR_PLUGINS")
      File.mkdir_p!(Path.join(dir, ".yoke"))
      File.write!(Path.join(dir, ".yoke/config.json"), ~s({"elixir_plugins": false}))
      refute ElixirPlugins.enabled?(dir, headless: true)
    end
  end

  describe "run_on_diff/2" do
    test "runs oeditus_credo, propwise, and credo on changed files and filters issues", %{
      dir: dir
    } do
      test_pid = self()

      runner = fn tool, args, _cwd ->
        send(test_pid, {:ran, tool, args})

        case tool do
          "oeditus_credo" ->
            {PayloadFixture.encode_oeditus(), 16}

          "credo" ->
            {~s({"diff":{"fixed":[],"new":[],"old":[]}}), 0}

          "propwise" ->
            {"Analyzing ....\n" <> PayloadFixture.encode_propwise(), 0}
        end
      end

      assert {:ok, report} =
               ElixirPlugins.run_on_diff(dir,
                 base_ref: "main",
                 changed_files: ["lib/demo/calc.ex", "test/demo/calc_test.exs"],
                 runner: runner
               )

      assert report.status == :ok
      assert_received {:ran, "oeditus_credo", ["diff", "main", "--format=json"]}

      assert_received {:ran, "propwise",
                       ["--files", "lib/demo/calc.ex", "--format", "json", "--no-fail"]}

      assert_received {:ran, "credo", ["diff", "main", "--format=json"]}

      [oeditus, propwise, credo] = report.results

      # Off-diff issue in lib/unrelated.ex is filtered out.
      assert oeditus.tool == "oeditus_credo"
      assert oeditus.total_issues == 1
      assert [%{file: "lib/demo/calc.ex", line: 2, priority: 14}] = oeditus.issues

      assert propwise.tool == "propwise"
      assert propwise.total_candidates == 1

      assert [%{module: "Demo.Calc", name: "add", arity: 2, file: "lib/demo/calc.ex"}] =
               propwise.candidates

      assert credo.tool == "credo"
      assert credo.total_issues == 0

      prompt = ElixirPlugins.format_for_prompt(report)
      assert prompt =~ "Elixir Language Plugins (diff)"
      assert prompt =~ "OeditusCredo.Check.Warning.MissingErrorHandling"
      assert prompt =~ "Demo.Calc.add/2"
      assert prompt =~ "test/demo/calc_test.exs"
      assert prompt =~ "actual test improvements"
      assert prompt =~ "property \"commutative\""

      summary = ElixirPlugins.format_summary(report)
      assert summary =~ "oeditus_credo: 1 issue(s)"
      assert summary =~ "propwise: 1 candidate(s)"
      assert summary =~ "credo: 0 issue(s)"
    end

    test "skips when opted out", %{dir: dir} do
      assert {:ok, %{status: :skipped, reason: :opted_out}} =
               ElixirPlugins.run_on_diff(dir,
                 changed_files: ["lib/demo/calc.ex"],
                 elixir_plugins: false
               )
    end

    test "handles plugin crash gracefully without failing", %{dir: dir} do
      runner = fn
        "propwise", _args, _cwd -> {"** (Mix) The task \"propwise\" could not be found", 1}
        _tool, _args, _cwd -> {~s({"diff":{"new":[]}}), 0}
      end

      assert {:ok, report} =
               ElixirPlugins.run_on_diff(dir,
                 changed_files: ["lib/demo/calc.ex"],
                 runner: runner
               )

      propwise = Enum.find(report.results, &(&1.tool == "propwise"))
      assert propwise.status == :error
      assert propwise.error =~ "could not be found"
    end
  end

  describe "PRReview and CLI opt-out integration" do
    test "parse_review_args/2 and CI.review_opts/1 support --no-elixir-plugins" do
      assert {:ok, "main", opts} = PRReview.parse_review_args("main --no-elixir-plugins")
      assert Keyword.get(opts, :elixir_plugins) == false

      assert [head: "HEAD", post: false, elixir_plugins: false] =
               CI.review_opts(elixir_plugins: false)
    end

    test "review_prompt/3 embeds <elixir_plugins> and respects opt-out", %{dir: dir} do
      context = %{
        cwd: dir,
        base: "main",
        head: "HEAD",
        base_sha: "abc123",
        head_sha: "HEAD",
        merge_base: "abc123",
        log: "commit",
        stat: "1 file changed",
        raw_diff: "diff --git a/lib/demo/calc.ex b/lib/demo/calc.ex\n",
        changed_paths: MapSet.new(["lib/demo/calc.ex"]),
        valid_lines: MapSet.new([{"lib/demo/calc.ex", 2}]),
        pr_number: nil,
        pr_url: nil,
        repository: nil,
        peer_comments: []
      }

      plugin_report = %{
        status: :ok,
        reason: nil,
        results: [
          %{
            tool: "propwise",
            status: :ok,
            total_candidates: 1,
            candidates: [
              %{
                module: "Demo.Calc",
                name: "add",
                arity: 2,
                file: "lib/demo/calc.ex",
                line: 2,
                score: 5,
                purity: "pure",
                laws: ["commutative"],
                patterns: ["Arithmetic"],
                suggestions: [
                  "property \"commutative\" do\n  assert Demo.Calc.add(a, b) == Demo.Calc.add(b, a)\nend"
                ]
              }
            ],
            error: nil
          }
        ]
      }

      prompt = PRReview.review_prompt(context, [], elixir_plugin_report: plugin_report)
      assert prompt =~ "<elixir_plugins>\n"
      assert prompt =~ "Elixir Language Plugins (diff)"
      assert prompt =~ "Demo.Calc.add/2"
      assert prompt =~ "actual, concrete test improvements"

      opted_out = PRReview.review_prompt(context, [], elixir_plugins: false)
      refute opted_out =~ "<elixir_plugins>\n"
      refute opted_out =~ "Elixir Language Plugins (diff)"
    end
  end

  describe "Audit integration" do
    test "Audit.collect/2 and build_prompt/2 include elixir_plugins and propwise test guidance",
         %{dir: dir} do
      facts = Audit.collect(dir, elixir_plugins: false)
      assert facts.elixir_plugins == %{status: :skipped, reason: :opted_out, results: []}
      assert Audit.format_facts(facts) =~ "opted out"

      facts_with_report =
        Audit.collect(dir,
          elixir_plugin_report: %{
            status: :ok,
            reason: nil,
            results: [
              %{
                tool: "propwise",
                status: :ok,
                total_candidates: 1,
                candidates: [
                  %{
                    module: "Demo.Calc",
                    name: "add",
                    arity: 2,
                    file: "lib/demo/calc.ex",
                    line: 2,
                    score: 5,
                    purity: "pure",
                    laws: ["commutative"],
                    patterns: ["Arithmetic"],
                    suggestions: [
                      "property \"commutative\" do\n  assert Demo.Calc.add(a, b) == Demo.Calc.add(b, a)\nend"
                    ]
                  }
                ],
                error: nil
              }
            ]
          }
        )

      prompt = Audit.build_prompt(facts_with_report)
      assert prompt =~ "Elixir Language Plugins (diff)"
      assert prompt =~ "Demo.Calc.add/2"
      assert prompt =~ "actual test improvements"
    end
  end
end

defmodule PayloadFixture do
  def encode_oeditus do
    Yoke.Json.encode!(%{
      "diff" => %{
        "fixed" => [],
        "new" => [
          %{
            "check" => "OeditusCredo.Check.Warning.MissingErrorHandling",
            "filename" => "./lib/demo/calc.ex",
            "line_no" => 2,
            "message" => "Missing error handling",
            "priority" => 14
          },
          %{
            "check" => "Credo.Check.Readability.ModuleDoc",
            "filename" => "lib/unrelated.ex",
            "line_no" => 1,
            "message" => "Ignore me",
            "priority" => 20
          }
        ],
        "old" => []
      }
    })
  end

  def encode_propwise do
    Yoke.Json.encode!(%{
      "candidates" => [
        %{
          "arity" => 2,
          "file" => "./lib/demo/calc.ex",
          "laws" => ["commutative"],
          "line" => 2,
          "module" => "Demo.Calc",
          "name" => "add",
          "patterns" => [%{"reason" => "Arithmetic", "type" => "algebraic"}],
          "purity" => "pure",
          "score" => 5,
          "suggestions" => [
            ~s|property "commutative" do\n  assert Demo.Calc.add(a, b) == Demo.Calc.add(b, a)\nend|
          ]
        }
      ],
      "candidates_count" => 1
    })
  end
end
