### Aged OPEN conflict via real gh and two GraphQL pages
exit: 0
stdout:
conflict:2026-10-22T08:34:13Z

stderr:


### Young conflict stays quiet
exit: 0
stdout:
conflict-clear

stderr:


### Removed label clears episode
exit: 0
stdout:
conflict-clear

stderr:


### CLOSED PR
exit: 0
stdout:

stderr:


### MERGED PR
exit: 0
stdout:
merged

stderr:


### UNKNOWN PR
exit: 0
stdout:

stderr:


### Label API failure remains nonzero
exit: 1
stdout:

stderr:
gh: disposable label lookup unavailable (HTTP 503)


### GitHub poll with no jq executable on PATH
exit: 0
stdout:
conflict:2026-10-22T08:34:16Z

stderr:


### Overlap: ## SCOPE
old.txt
exit: 0
# Task
## SCOPE
old.txt
<!-- fm-pr-overlap:start -->
## SHARED
Open pull requests touching the planned files:
- https://github.com/o/r/pull/1 (old.txt)
- https://github.com/o/r/pull/2 (old.txt)
Unchecked open pull requests:
- https://github.com/o/r/pull/3 (unchecked: could not read changed files)
<!-- fm-pr-overlap:end -->
## Work
Make a change.


### Overlap: FILES: old.txt
exit: 0
# Task
FILES: old.txt
## Work
Make a change.
<!-- fm-pr-overlap:start -->
## SHARED
Open pull requests touching the planned files:
- https://github.com/o/r/pull/1 (old.txt)
- https://github.com/o/r/pull/2 (old.txt)
Unchecked open pull requests:
- https://github.com/o/r/pull/3 (unchecked: could not read changed files)
<!-- fm-pr-overlap:end -->


### Overlap: BLAST RADIUS:
- old.txt
exit: 0
# Task
BLAST RADIUS:
- old.txt
## Work
Make a change.
<!-- fm-pr-overlap:start -->
## SHARED
Open pull requests touching the planned files:
- https://github.com/o/r/pull/1 (old.txt)
- https://github.com/o/r/pull/2 (old.txt)
Unchecked open pull requests:
- https://github.com/o/r/pull/3 (unchecked: could not read changed files)
<!-- fm-pr-overlap:end -->


### Overlap: ## SCOPE
new.txt
exit: 0
# Task
## SCOPE
new.txt
<!-- fm-pr-overlap:start -->
## SHARED
Open pull requests touching the planned files:
- https://github.com/o/r/pull/1 (new.txt)
- https://github.com/o/r/pull/2 (new.txt)
Unchecked open pull requests:
- https://github.com/o/r/pull/3 (unchecked: could not read changed files)
<!-- fm-pr-overlap:end -->
## Work
Make a change.


### Overlap: ## SCOPE
other.txt
exit: 0
# Task
## SCOPE
other.txt
<!-- fm-pr-overlap:start -->
## SHARED
No overlap found among 2 compared open pull requests.
Unchecked open pull requests:
- https://github.com/o/r/pull/3 (unchecked: could not read changed files)
<!-- fm-pr-overlap:end -->
## Work
Make a change.


### Overlap: No paths provided
exit: 0
# Task
No paths provided
## Work
Make a change.
<!-- fm-pr-overlap:start -->
## SHARED
Overlap was not checked: no planned paths found in SCOPE, FILES, or BLAST RADIUS.
<!-- fm-pr-overlap:end -->


Overlap leaves source checkout unchanged.

### Live watcher delivery
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.l


Inbox message files after repeated polling: 1

### Real worker merge result
*   8a4f988 Merge origin/main into lane
|\  
| * e5e1104 main change
* | b0b0178 worker change
|/  
| * 1155222 rename
|/  
* 5bfffbb base

main
worker

remote lane before=b0b017858e963dafe8107150c7541dfd843b3ad4
after=8a4f9885ae673ef6c37fce3f7c56eada4f246760

### Watcher legacy-fallback
exit before stop: None
stdout:
check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/watch-legacy-fallback/state/lane.check.sh: conflict

stderr:

notifications:
1792659316	1	check	~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/watch-legacy-fallback/state/lane.check.sh	check: ~/.no-mistakes/worktrees/11bdc1ed0d7a/01M5H8ZXZRA1N26RZ4DE5CK27Q/.live-test-tmp/manual/watch-legacy-fallback/state/lane.check.sh: conflict

### Watcher closed
exit before stop: None
stdout:

stderr:

notifications:
