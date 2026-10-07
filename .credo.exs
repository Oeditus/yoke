%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: [
        {Credo.Check.Readability.MaxLineLength, [max_length: 140]},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 40]},
        {Credo.Check.Refactor.Nesting, [max_nesting: 6]},
        {Credo.Check.Design.AliasUsage, [if_nested_deeper_than: 3]}
      ]
    }
  ]
}
