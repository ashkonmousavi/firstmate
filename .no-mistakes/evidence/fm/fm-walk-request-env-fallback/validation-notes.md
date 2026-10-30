# Walk-request environment fallback validation

Scope: ce32074f8cec0a445f97f94079c46045504dbf17 → bfb3bbf9364c9f00c483a0d2f458497db57f5db1.

## Oracles and research

The supplied owner intent requires a watcher started before routing configuration was written to forward `--project` and `--target` without a manual dispatch. The changed script's documented compatibility contract preserves explicit environment precedence, all-or-neither route validation, optional routing when no configuration exists, and non-execution of configuration text.

GNU Bash documents inheritance of exported variables by executed commands: [Environment](https://www.gnu.org/software/bash/manual/html_node/Environment.html). Its [execution environment documentation](https://www.gnu.org/software/bash/manual/html_node/Command-Execution-Environment.html) also explains child-process environments. Primary-source search through Exa and runtime web search supports the stale-environment mechanism; no external dependency change is needed to explain this report. The private research-book index is absent from this checkout and operator user-data access is excluded by the test brief. This evidence note records the research inside the authorized boundary.

## Evidence and limits

`targeted-suite.log` is the completed, passing `tests/fm-walk-request.test.sh` run. This focused suite uses dispatcher/transport fakes and is not live product evidence.

`manual-transcript.log` records real `fm-walk-request-check.sh check` invocations with disposable homes for absent configuration, explicit environment precedence over invalid file contents, rejection of partial environment/file routing, command-substitution and command-line non-execution, malformed routing rejection, and the config-directory override. These CLI checks use no dispatcher or transport mock.

The same transcript also records a before/after integration probe with the real carrier, real registered watcher, real checker and real `fm-send` durable inbox. It starts the watcher before creating `watch.env`. A test double at the home-private dispatcher boundary records argv and returns the independently specified missing-pair failure or accepts the fixed x/production pair. Baseline argv lacks both flags and the real inbox receives the reported exit-2 failure; target argv includes `--project x --target production` and the real inbox receives exit 0. Quoted/exported values and last-assignment selection are exercised in that probe. Each record is delivered once. This is supplemental mock-backed evidence, not a live authenticated bot walk.

The first probe setup inadvertently ran the target from the baseline-generated shim, which hardcodes the canonical checker filename. The corrected baseline fixture explicitly points its generated shim at the old checker and re-registers its bytes. The second setup error expected success wording on a deliberately failing baseline outcome. Both setup errors were independently reviewed and corrected; their transcripts are retained separately. The final driver exited 0 and each watcher was reaped with exit 0. All detached dispatcher result logs have recorded exit status.

The worktree does not contain the default `data/bin/fm-grok-bot-dispatch.sh`, its bridge, or an authorized isolated bot target. Accessing the real operator home or shared bot service would violate the explicit validation boundary. A local test double cannot establish authenticated downstream success. Full user-intent live validation therefore remains untested; provide a disposable dispatcher/bridge and authorized isolated target within the worktree to complete it. No source change was required.

This is a CLI/configuration change; no rendered UI or screenshot surface was exercised. All disposable fixture homes and temporary baseline files were removed after the checks. Evidence files remain here.
