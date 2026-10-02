#!/usr/bin/env bash
# Live driver: real bin/fm-brief.sh and bin/fm-spawn.sh against a disposable marked lab FM_HOME.
# The only substitute is a `tmux` shim that exits 1, so a spawn that clears admission stops
# at endpoint creation (no worker, no treehouse slot) after rendering its launch brief.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/shim" "$LAB/projects/proj"
printf '#!/bin/sh\nexit 1\n' > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
git -C "$LAB/projects/proj" init -q && git -C "$LAB/projects/proj" -c user.name=lab -c user.email=lab@x commit -q --allow-empty -m init
CLEAN=(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
brief() { echo "\$ fm-brief.sh $*"; "${CLEAN[@]}" "$WT/bin/fm-brief.sh" "$@" 2>&1; echo "[exit $?]"; }
spawn() { local id=$1; rm -f "$LAB/data/$id/launch-brief.md"
  echo "\$ fm-spawn.sh $id <lab-proj> claude --mode no-mistakes --yolo off"
  "${CLEAN[@]}" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/shim:$PATH" \
    "$WT/bin/fm-spawn.sh" "$id" "$LAB/projects/proj" claude --mode no-mistakes --yolo off 2>&1 | grep -E 'preparation record|reviews its preparation|^error' | cut -c1-400
  if [ -f "$LAB/data/$id/launch-brief.md" ]; then echo "RESULT: admitted (launch-brief.md rendered)";
    grep -q 'Accepted specification for --intent' "$LAB/data/$id/launch-brief.md" && echo "  launch brief HAS accepted-spec overlay" || echo "  launch brief has NO accepted-spec overlay"
  else echo "RESULT: refused (no launch brief)"; fi; }
mkbrief() { local id=$1; mkdir -p "$LAB/data/$id"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nFix the typo.\n\n## Firstmate spec\nFix it.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\nShip branch: fm/%s\n' "$id" > "$LAB/data/$id/brief.md"; }
fill_cert() { sed -E -e 's/\{Q1\}/no/' -e 's/\{Q2\}/no/' -e 's/\{UI_WIRING\}/no, internal script output only./' \
  -e 's/\{Q[12]_REASON\}/Inspected the one confined helper./' -e 's/\{C[1-5]\}/yes/' \
  -e 's/\{C[1-5]_EVIDENCE\}/bin\/owned.sh:12; rg owned_fn returned only bin\/owned.sh; no stored data, security, permissions, money, install or server path; cause reproduced by bash tests\/owned.test.sh; red-first regression./' "$1" > "$1.f" && mv "$1.f" "$1"; }

echo "=== S1: surgical scaffold through the existing --prep entry point ==="
brief cert-ok --prep --surgical
cat "$LAB/data/cert-ok/prep.md"
echo; echo "=== S2: --surgical guards ==="
brief guard-a --surgical
brief guard-b --prep --surgical --mode no-mistakes
brief guard-c --prep --surgical --forge gerrit
brief cert-ok --prep --surgical
echo "--- plain --prep stays the full scaffold (Q2 wording + Size guide) ---"
brief full-a --prep
grep -nE '^- Q2|^## 12|Split by|eight' "$LAB/data/full-a/prep.md"

echo; echo "=== S3: complete all-yes certificate is admitted without a prep review ==="
mkbrief cert-ok; fill_cert "$LAB/data/cert-ok/prep.md"
ls "$LAB/data/cert-ok"; spawn cert-ok

echo; echo "=== S4: doubt refuses (C4 unsure / C2 no / evidence-free C5 / only Q1 Reason removed) ==="
for v in c4-unsure c2-no c5-noevidence q1-reason-missing; do
  mkbrief "$v"; brief "$v" --prep --surgical >/dev/null; p="$LAB/data/$v/prep.md"; fill_cert "$p"
  case $v in
    c4-unsure) sed -i 's/^\(- C4 .*\): yes$/\1: unsure/' "$p" ;;
    c2-no) sed -i 's/^\(- C2 .*\): yes$/\1: no/' "$p" ;;
    c5-noevidence) awk '/^- C5 /{print; skip=1; next} skip && /^Evidence:/{skip=0; next} {print}' "$p" > "$p.x" && mv "$p.x" "$p" ;;
    q1-reason-missing) awk '/^Reason:/ && ++n==1 {next} {print}' "$p" > "$p.x" && mv "$p.x" "$p" ;;
  esac
  echo "--- $v ---"; grep -nE '^- (Q1|Q2|C2|C4|C5) |^Reason:' "$p" | head -4; spawn "$v"
done

echo; echo "=== S5: shared-scope (Q2 yes) surgical certificate is ineligible ==="
mkbrief cert-shared; brief cert-shared --prep --surgical >/dev/null; fill_cert "$LAB/data/cert-shared/prep.md"
sed -i 's/^\(- Q2 .*\): no$/\1: yes/' "$LAB/data/cert-shared/prep.md"; spawn cert-shared

echo; echo "=== S6: legacy all-no header-only record no longer ships ==="
mkbrief legacy0; brief legacy0 --prep >/dev/null; p="$LAB/data/legacy0/prep.md"
awk '/^## Tier/{t=1} t && /^## [0-9]/{exit} {print}' "$p" | sed -e 's/{Q1}/no/' -e 's/{Q2}/no/' -e 's/{UI_WIRING}/no, internal./' > "$p.x" && mv "$p.x" "$p"
cat "$p"; spawn legacy0
echo "--- same all-no answers with tier-1 sections filled but no review ---"
mkbrief legacy1; brief legacy1 --prep >/dev/null; p="$LAB/data/legacy1/prep.md"
sed -e 's/{Q1}/no/' -e 's/{Q2}/no/' -e 's/{UI_WIRING}/no, internal./' -e 's/^{[A-Z0-9_]*}$/n\/a: lab fixture./' "$p" > "$p.x" && mv "$p.x" "$p"
# Blast radius needs its tool-evidence token
sed -i '/^## 4\./,/^## 5\./ s/^n\/a: lab fixture\.$/gitnexus impact owned_fn: 0 callers; serena find_referencing_symbols: none./' "$p"
spawn legacy1
echo "--- after a byte-bound separate review ---"
r=legacy1-prep-review; mkdir -p "$LAB/data/$r"; printf 'reviewer=%s\nauthor=firstmate\n' "$r" > "$LAB/data/legacy1/prep-review"
printf 'role\n' > "$LAB/data/$r/launch-brief.md"; printf '## Standards\nok\n## Spec\nok\n' > "$LAB/data/$r/report.md"
mkdir -p "$LAB/data/$r/reviewed-prep"; cp "$p" "$LAB/data/$r/reviewed-prep/legacy1.md"; spawn legacy1

echo; echo "=== S7: explicit four-no server-install exemption still skips review ==="
mkbrief srv; cp "$LAB/data/legacy1/prep.md" "$LAB/data/srv/prep.md"
sed -i 's/^- UI wiring: .*/&\n- Prep review exemption: server-install\n- Changes unit: no\n- Changes setting: no\n- Changes pin: no\n- Changes store version: no/' "$LAB/data/srv/prep.md"
grep -n '^- ' "$LAB/data/srv/prep.md" | head -8; spawn srv
echo "--- server-install header with all-no but no tier-1 sections ---"
mkbrief srv0; cp "$LAB/data/legacy0/prep.md" "$LAB/data/srv0/prep.md"
sed -i 's/^- UI wiring: .*/&\n- Prep review exemption: server-install\n- Changes unit: no\n- Changes setting: no\n- Changes pin: no\n- Changes store version: no/' "$LAB/data/srv0/prep.md"; spawn srv0
