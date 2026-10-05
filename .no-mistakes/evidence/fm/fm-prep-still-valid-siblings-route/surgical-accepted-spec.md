
# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.
The one addition is the accepted specification below, from this task's complete preparation record: after the captain's words, add a blank line, then the line `Accepted specification from the preparation record (not the captain's words):`, then every heading and body under `## Accepted specification for --intent (preparation record, not the captain's words)` exactly as written, so the review checks the work against what the record promised.
It is specification, not captain intent; `## Firstmate spec`, later Firstmate constraints, and your own decisions and tradeoffs still stay out.

## Accepted specification for --intent (preparation record, not the captain's words)
## Expected outcomes and how to check each
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| O1: A researcher opens the assigned study, saves the comparison and reopens it | The researcher starting from the study page selects both candidates, saves their comparison, returns home and reopens the same saved comparison with both candidates retained. | Execution owner: test phase; disposable local home; fixture evidence class; inspect generated prep and accepted-spec overlay, then cite actual observation in the existing evidence directory. | The independently requested task is to retain both candidates after reopen; actual walked observation belongs in delivery evidence, with permitted console and network diagnosis on failure. |

## Captain intent authorized for --intent
Walk the assigned study and reopen its saved comparison.
