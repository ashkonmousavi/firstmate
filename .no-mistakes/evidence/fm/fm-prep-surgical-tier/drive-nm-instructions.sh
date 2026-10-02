#!/usr/bin/env bash
# Live driver: real bin/fm-brief.sh (ship, both forges) and bin/fm-promote.sh in a disposable lab FM_HOME;
# prints the generated worker-facing no-mistakes triage text and checks removed rules are gone.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
CLEAN=(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
check() { local f=$1 label=$2
  echo "##### $label: $f"
  awk '/^Review triage and class-fix handoff:/,/banned fleet-wide/' "$f"
  echo "--- stop-set escalation shape ---"; grep -n 'escalated findings=\|key=nm-<run>-<step>\|nm-<run>-findings.txt' "$f" | cut -c1-220
  echo "--- removed rules (expect no matches) ---"
  grep -nE 'second review round|two-round|ask-user findings are never yours|ask-user findings=' "$f" || echo "none"
  echo "--- --yes ban present ---"; grep -c 'NEVER pass `--yes`' "$f"; echo; }
"${CLEAN[@]}" "$WT/bin/fm-brief.sh" nm-plain proj --mode no-mistakes >/dev/null 2>&1; echo "brief nm-plain rc=$?"
"${CLEAN[@]}" "$WT/bin/fm-brief.sh" nm-gerrit proj --mode no-mistakes --forge gerrit >/dev/null 2>&1; echo "brief nm-gerrit rc=$?"
"${CLEAN[@]}" "$WT/bin/fm-brief.sh" dpr proj --mode direct-PR >/dev/null 2>&1; echo "brief dpr rc=$?"
check "$LAB/data/nm-plain/brief.md" "ordinary ship, forge none"
check "$LAB/data/nm-gerrit/brief.md" "ordinary ship, forge gerrit"
echo "##### direct-PR brief carries no no-mistakes triage block:"; grep -c 'Review triage and class-fix handoff' "$LAB/data/dpr/brief.md"
# promoted scout
id=promo; mkdir -p "$LAB/state"; printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$LAB/state/$id.meta"
"${CLEAN[@]}" "$WT/bin/fm-brief.sh" "$id" proj --scout >/dev/null 2>&1; echo "scout brief rc=$?"
b="$LAB/data/$id/brief.md"
awk '/^## Captain.s intent/{print; getline; print "Ship the promoted fix."; next} /^## Firstmate spec/{print; getline; print "Preserve delivery."; next} {print}' "$b" | sed 's/{TASK}//; s/{FIRSTMATE_SPEC}//' > "$b.x" && mv "$b.x" "$b"
"${CLEAN[@]}" "$WT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1 | head -5; echo "promote rc=${PIPESTATUS[0]}"
check "$LAB/data/$id/ship-instructions.md" "promoted scout (no-mistakes)"
grep -n 'stop-set escalation below supersedes\|including the stop set' "$LAB/data/$id/ship-instructions.md" | cut -c1-200
