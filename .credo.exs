%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/"
        ]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled:
          # ---------------------------------------------------------------
          # Default Credo checks (standard --strict set)
          # ---------------------------------------------------------------
          [
            {Credo.Check.Consistency.ExceptionNames, []},
            {Credo.Check.Consistency.LineEndings, []},
            {Credo.Check.Consistency.ParameterPatternMatching, []},
            {Credo.Check.Consistency.SpaceAroundOperators, []},
            {Credo.Check.Consistency.SpaceInParentheses, []},
            {Credo.Check.Consistency.TabsOrSpaces, []},
            {Credo.Check.Design.AliasUsage,
             [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
            {Credo.Check.Design.TagTODO, [exit_status: 2]},
            {Credo.Check.Design.TagFIXME, []},
            {Credo.Check.Readability.AliasOrder, []},
            {Credo.Check.Readability.FunctionNames, []},
            {Credo.Check.Readability.LargeNumbers, []},
            {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
            {Credo.Check.Readability.ModuleAttributeNames, []},
            {Credo.Check.Readability.ModuleDoc, []},
            {Credo.Check.Readability.ModuleNames, []},
            {Credo.Check.Readability.ParenthesesInCondition, []},
            {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
            {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
            {Credo.Check.Readability.PredicateFunctionNames, []},
            {Credo.Check.Readability.PreferImplicitTry, []},
            {Credo.Check.Readability.RedundantBlankLines, []},
            {Credo.Check.Readability.Semicolons, []},
            {Credo.Check.Readability.SpaceAfterCommas, []},
            {Credo.Check.Readability.StringSigils, []},
            {Credo.Check.Readability.TrailingBlankLine, []},
            {Credo.Check.Readability.TrailingWhiteSpace, []},
            {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
            {Credo.Check.Readability.VariableNames, []},
            {Credo.Check.Readability.WithSingleClause, []},
            {Credo.Check.Refactor.Apply, []},
            {Credo.Check.Refactor.CondStatements, []},
            {Credo.Check.Refactor.CyclomaticComplexity, []},
            {Credo.Check.Refactor.FunctionArity, []},
            {Credo.Check.Refactor.LongQuoteBlocks, []},
            {Credo.Check.Refactor.MatchInCondition, []},
            {Credo.Check.Refactor.MapJoin, []},
            {Credo.Check.Refactor.NegatedConditionsInUnless, []},
            {Credo.Check.Refactor.NegatedConditionsWithElse, []},
            {Credo.Check.Refactor.Nesting, []},
            # Scoped to lib/ — test code idiomatically starts pipes with build_conn()/Plug.Test.conn()
            {Credo.Check.Refactor.PipeChainStart, [files: %{included: ["lib/"]}]},
            {Credo.Check.Refactor.UnlessWithElse, []},
            {Credo.Check.Refactor.WithClauses, []},
            {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
            {Credo.Check.Warning.BoolOperationOnSameValues, []},
            {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
            {Credo.Check.Warning.IExPry, []},
            {Credo.Check.Warning.IoInspect, []},
            {Credo.Check.Warning.MixEnv, []},
            {Credo.Check.Warning.OperationOnSameValues, []},
            {Credo.Check.Warning.OperationWithConstantResult, []},
            {Credo.Check.Warning.RaiseInsideRescue, []},
            {Credo.Check.Warning.SpecWithStruct, []},
            {Credo.Check.Warning.UnsafeExec, []},
            {Credo.Check.Warning.UnusedEnumOperation, []},
            {Credo.Check.Warning.UnusedFileOperation, []},
            {Credo.Check.Warning.UnusedKeywordOperation, []},
            {Credo.Check.Warning.UnusedListOperation, []},
            {Credo.Check.Warning.UnusedPathOperation, []},
            {Credo.Check.Warning.UnusedRegexOperation, []},
            {Credo.Check.Warning.UnusedStringOperation, []},
            {Credo.Check.Warning.UnusedTupleOperation, []},
            {Credo.Check.Warning.WrongTestFileExtension, []}
          ] ++
            # ---------------------------------------------------------------
            # Jump Credo Checks — selective picks
            #
            # Skipped (not relevant to this codebase):
            #   - UseObanProWorker: no Oban usage
            #   - PreferTextColumns: no migrations in this library
            #   - LiveViewFormCanBeRehydrated: no LiveView
            #   - AssertElementSelectorCanNeverFail: no LiveView tests
            #   - AvoidSocketAssignsInTest: no LiveView tests
            #   - DoctestIExExamples: low value for this codebase
            #   - ForbiddenFunction: no project-specific dangerous functions identified yet
            # ---------------------------------------------------------------
            [
              # Encourages pattern matching / early returns over function-level else
              {Jump.CredoChecks.AvoidFunctionLevelElse, []},

              # Ensures aliases, imports, requires are at the top of the module body
              {Jump.CredoChecks.TopLevelAliasImportRequire, []},

              # Catches tests with no assertions (dead tests)
              {Jump.CredoChecks.TestHasNoAssertions, []},

              # Catches vacuous tests (e.g. assert true)
              {Jump.CredoChecks.VacuousTest, []},

              # Catches weak assertions (e.g. assert something != nil)
              {Jump.CredoChecks.WeakAssertion, []},

              # Prevents bloated tests — keeps tests focused
              {Jump.CredoChecks.TooManyAssertions, [max_assertions: 10]},

              # Prevents Logger.configure in tests which can leak across the suite
              {Jump.CredoChecks.AvoidLoggerConfigureInTest, []}
            ] ++
            # ---------------------------------------------------------------
            # Blitz Credo Checks — selective picks
            #
            # Skipped (not relevant or too stylistic):
            #   - ConcurrentIndexMigrations: no migrations in this library
            #   - DocsBeforeSpecs: stylistic, low signal
            #   - DoctestIndent: stylistic, low signal
            #   - ImproperImport: already covered by Credo.Check.Design.AliasUsage
            #   - LowercaseTestNames: stylistic preference, not enforced here
            #   - NoDSLParentheses: stylistic, low signal
            #   - NoIsBitstring: rarely encountered
            #   - NoAsyncFalse: no async test cases in this project
            #   - TodosNeedTickets: no ticket URL convention established yet
            #   - StrictComparison: existing codebase uses == pervasively (99 hits),
            #     would require a large refactor — enable later if desired
            # ---------------------------------------------------------------
            [
              # Prevents scattered Repo calls — encourages context modules.
              # Sink is the context here; the Repo module is the Repo itself;
              # and test modules legitimately set up / assert via Repo.
              {BlitzCredoChecks.NoRampantRepos,
               allowed_modules: [
                 [:DataCase],
                 [:ChannelCase],
                 [:Application],
                 [:Sink],
                 [:Repo],
                 [:SinkTest],
                 [:SinkRepoOverrideTest],
                 [:SinkResilienceTest],
                 [:EventTest],
                 [:EventJsonTest],
                 [:EventJsonConformanceTest],
                 [:IngestIntegrationTest]
               ],
               files: %{excluded: ["test/test_helper.exs"]}},

              # Encourages Stream over Enum for large/lazy pipelines
              {BlitzCredoChecks.UseStream, []},

              # Disabled: this check wants `Code.put_compiler_option/2`
              # in test/test_helper.exs, but that API is deprecated in
              # Elixir 1.19. The equivalent is set project-wide via
              # `elixirc_options: [warnings_as_errors: true]` in mix.exs.
              {BlitzCredoChecks.SetWarningsAsErrorsInTest, false}
            ] ++
            # ---------------------------------------------------------------
            # Oeditus Credo Checks — complementary to Sobelow
            #
            # Sobelow already covers: SQL injection, OS command injection,
            # code injection, XSS, CSRF, path traversal, unsafe deserialization.
            # Those checks are DISABLED here to avoid redundancy.
            #
            # Disabled (redundant with Sobelow):
            #   - SQLInjection, OSCommandInjection, CodeInjection,
            #     XSSVulnerability, PathTraversal, UnsafeDeserialization,
            #     MissingCSRFProtection
            #
            # Disabled (not relevant to this codebase):
            #   - CallbackHell: low signal for a small plug library
            #   - DirectStructUpdate: stylistic, Elixir norm
            #   - InlineJavascript: no HTML/templates
            #   - MissingTelemetry*: no telemetry convention established
            #   - TelemetryInRecursiveFunction: no telemetry
            #   - MissingThrottle: not applicable to a plug library
            #   - NPlusOneQuery, MissingPreload: no Ecto queries
            #   - UnrestrictedFileUpload: no file upload handling
            #   - MissingAuthentication, MissingAuthorization,
            #     IncorrectAuthorization, InsecureDirectObjectReference:
            #     authz policy checks — too opinionated for a plug library
            #     where auth is handled upstream by the consuming application
            #   - ImproperInputValidation: overlaps with Plug input validation
            #     patterns and would be noisy on a library that validates by design
            # ---------------------------------------------------------------

            # -- Security checks (Oeditus-only, NOT covered by Sobelow) --
            [
              # Detects user-controlled URLs passed to HTTP clients (Req, Finch, etc.)
              {OeditusCredo.Check.Security.SSRFVulnerability, []},

              # Detects hardcoded secrets/credentials in source code
              # Broader than Sobelow which only checks config files
              {OeditusCredo.Check.Security.HardcodedCredentials, []},

              # Detects time-of-check/time-of-use race conditions
              # Relevant to the idempotency/caching logic
              {OeditusCredo.Check.Security.TOCTOU, []},

              # Detects sensitive data (tokens, keys) potentially leaked in logs/responses
              # Broader than Sobelow's config-only checks
              {OeditusCredo.Check.Security.SensitiveDataExposure, []}
            ] ++

            # -- Warning checks (code quality / error handling) --
            [
              # Catches bare function calls without error handling
              # Scoped to lib/ only — test setup `:ok` matches are intentional
              {OeditusCredo.Check.Warning.MissingErrorHandling,
               [files: %{included: ["lib/"]}]},

              # Catches case clauses that silently discard error tuples
              {OeditusCredo.Check.Warning.SilentErrorCase, []},

              # Catches rescue/catch blocks that swallow exceptions without logging
              {OeditusCredo.Check.Warning.SwallowingException, []},

              # Catches Enum.filter |> Enum.count instead of Enum.count(fn)
              {OeditusCredo.Check.Warning.InefficientFilter, []},

              # Catches unsupervised Task.async without Task.await
              {OeditusCredo.Check.Warning.UnmanagedTask, []},

              # Catches synchronous calls that could be async (e.g. blocking GenServer.call)
              {OeditusCredo.Check.Warning.SyncOverAsync, []},

              # Catches missing handle_info for Task.async results
              {OeditusCredo.Check.Warning.MissingHandleAsync, []},

              # Catches blocking operations inside plug call/2 (e.g. long HTTP calls)
              {OeditusCredo.Check.Warning.BlockingInPlug, []}
            ],
        disabled: []
      }
    }
  ]
}
