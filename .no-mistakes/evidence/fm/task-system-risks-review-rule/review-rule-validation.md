# Review RISKS rule: test-phase result

Result: inconclusive. No live review scenario was driven; no product failure was observed.

Change: target 48e368b4355ea608501eb84d3feae08a8f9d9c2e appends one review.path_instructions entry to .no-mistakes.yaml relative to d23d07ade96bf4ccfae4275e4d4c63b673462c33. No executable Firstmate code changes.

## Checks completed

- Inspected the complete base-to-target diff and the supplied verification plan.
- Parsed both configurations with Python yaml.safe_load. Checked the review-rule sequence and nonempty string field types; removed the appended entry from the normalized target model and compared the full remaining model with the base. Result: one appended rule, path '*', 319 instruction bytes, all earlier configuration semantics preserved. This is configuration compatibility evidence only, not proof of prompt delivery or model interpretation.
- Inspected installed no-mistakes 1.100.1+fleet.r10.1 root, axi, eval and eval run help. All returned status 0. Full CLI output and exit statuses are in review-consumer-capabilities.log.
- Consulted the official configuration reference: https://kunchenguid.github.io/no-mistakes/reference/repo-config/#reviewpath_instructions and #ignore_patterns. It documents trusted-default loading, basename matching for slashless patterns at every depth, and additive application of distinct instructions sharing a path. Documentation describes the contract; it is not empirical evidence for this installed binary.

## Scenarios and independent expectations

The supplied user intent is the oracle for missing-RISKS findings and G1-G11 coverage. The supplied plan describes informational severity and docs/pointer exceptions; the changed instruction states the same scope.

1. Add or modify a gate, check, hook, owl source or admission path at root or arbitrary nesting with an absent RISKS line, empty RISKS line or a line containing no G1-G11 id: expect a nonblocking informational finding. Untested.
2. Review governance changes whose PR body has a nonempty RISKS line naming each valid G1-G11 id: expect no missing-RISKS finding. Untested.
3. Review a docs-only PR without a RISKS line: expect no missing-RISKS finding. Untested.
4. Review pointer-only edits with RISKS: none - <reason>: expect no missing-RISKS finding; try the same waiver on substantive governance code, or omit its reason: expect an informational finding. Untested.

## Why live proof is unavailable in this phase

The real consumer is the no-mistakes Review step. That step ignores feature-branch review instructions and loads its trusted default-branch copy. The installed CLI exposes no config matcher or prompt-preview command. Eval run only replays previously captured review passes and offers no candidate-config or PR-body input; replaying old prompts would not test this change. No operator cases or configuration were accessed. Creating a disposable repository and running a new gate would still require starting another pipeline and executing the Review phase, both explicitly forbidden to this Test agent. A standalone model prompt would bypass the actual consumer and cannot prove matching, trust loading or emitted prompts. Altering trusted configuration or manufacturing reviews was not attempted.

To obtain proof, the outer executor must arrange an authorized real Review run with this rule present in its trusted default-branch configuration and retain the actual prompts/findings for these cases. No new package, login or credential was needed for the permitted inspections. The outstanding requirement is authority to exercise that separate phase against the trusted rule.

No full suite, linter, formatter, static analyzer, pipeline-control command, PR mutation or fleet lifecycle action was run. No UI rendering changed, so visual evidence is inapplicable. No source or permanent tests were changed, and no disposable server/browser was started.
