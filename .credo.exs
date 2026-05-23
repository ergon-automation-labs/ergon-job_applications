%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.MaxLineLength, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []}
        ]
      }
    }
  ]
}
