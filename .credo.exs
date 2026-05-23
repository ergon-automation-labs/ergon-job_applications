%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          # Disabled to avoid false positives with fully-qualified module names
          # that are intentionally explicit for clarity across bot boundaries.
          {Credo.Check.Design.AliasUsage, []},

          # Logger metadata keys are set dynamically; configuring all possible
          # keys in the Logger backend is impractical for this codebase.
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},

          # Nesting depth of 2 is too strict for natural GenServer callbacks.
          {Credo.Check.Refactor.Nesting, []},

          # Alias ordering is a stylistic preference that doesn't affect
          # correctness; managing it across a large monorepo is noise.
          {Credo.Check.Readability.AliasOrder, []},

          # Cyclomatic complexity threshold of 9 is too strict for complex
          # business logic with multiple validation branches and conditions.
          {Credo.Check.Refactor.CyclomaticComplexity, []},

          # Predicate naming: is_ prefix vs ? suffix is a style choice.
          {Credo.Check.Readability.PredicateFunctionNames, []},

          # Enum.map_join vs map+join: both are acceptable patterns.
          {Credo.Check.Refactor.MapJoin, []},

          # Negated conditions: sometimes more readable than alternatives.
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},

          # Variable naming pattern is a style preference.
          {Credo.Check.Consistency.ParameterPatternMatching, []}
        ]
      }
    }
  ]
}
