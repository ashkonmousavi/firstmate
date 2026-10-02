#!/usr/bin/env bash
# Live driver (same lab setup as drive-prep-admission.sh): server-install with one `yes`,
# and accepted-spec overlay presence for a reviewed full record vs absence for a surgical certificate.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/shim" "$LAB/projects/proj"
printf '#!/bin/sh\nexit 1\n' > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
git -C "$LAB/projects/proj" init -q && git -C "$LAB/projects/proj" -c user.name=lab -c user.email=lab@x commit -q --allow-empty -m init
CLEAN=(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
spawn() { local id=$1; rm -f "$LAB/data/$id/launch-brief.md"
  echo "\$ fm-spawn.sh $id <lab-proj> claude --mode no-mistakes --yolo off"
  "${CLEAN[@]}" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX_TMPDIR="$LAB/tmux" PATH="$LAB/shim:$PATH" \
    "$WT/bin/fm-spawn.sh" "$id" "$LAB/projects/proj" claude --mode no-mistakes --yolo off 2>&1 | grep -E 'preparation record|reviews its preparation|^error' | cut -c1-300
  if [ -f "$LAB/data/$id/launch-brief.md" ]; then echo "RESULT: admitted (launch-brief.md rendered)"
    if grep -q 'Accepted specification for --intent' "$LAB/data/$id/launch-brief.md"; then echo "  overlay PRESENT:"; awk '/Accepted specification for --intent/{p=1} p' "$LAB/data/$id/launch-brief.md" | head -12 | sed 's/^/    /'; else echo "  overlay ABSENT"; fi
  else echo "RESULT: refused (no launch brief)"; fi; }
mkbrief() { mkdir -p "$LAB/data/$1"; printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nFix the typo.\n\n## Firstmate spec\nFix it.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\nShip branch: fm/%s\n' "$1" > "$LAB/data/$1/brief.md"; }
fullrec() { local id=$1 p="$LAB/data/$1/prep.md"; "${CLEAN[@]}" "$WT/bin/fm-brief.sh" "$id" --prep >/dev/null
  sed -e 's/{Q1}/no/' -e 's/{Q2}/no/' -e 's/{UI_WIRING}/no, internal./' -e 's/^{[A-Z0-9_]*}$/n\/a: lab fixture./' "$p" > "$p.x" && mv "$p.x" "$p"
  sed -i '/^## 4\./,/^## 5\./ s/^n\/a: lab fixture\.$/gitnexus impact owned_fn: 0 callers; serena find_referencing_symbols: none./' "$p"; }
review() { local id=$1 r=$1-prep-review; mkdir -p "$LAB/data/$r/reviewed-prep"; printf 'reviewer=%s\nauthor=firstmate\n' "$r" > "$LAB/data/$id/prep-review"
  printf 'role\n' > "$LAB/data/$r/launch-brief.md"; printf '## Standards\nok\n## Spec\nok\n' > "$LAB/data/$r/report.md"; cp "$LAB/data/$id/prep.md" "$LAB/data/$r/reviewed-prep/$id.md"; }
srvdecl() { sed -i "s/^- UI wiring: .*/&\n- Prep review exemption: server-install\n- Changes unit: no\n- Changes setting: no\n- Changes pin: $2\n- Changes store version: no/" "$LAB/data/$1/prep.md"; }

echo "=== server-install: four no -> exempt; one yes -> needs review ==="
for v in no yes; do id=srv-pin-$v; mkbrief $id; fullrec $id; srvdecl $id $v; grep -n '^- Changes pin' "$LAB/data/$id/prep.md"; spawn $id; done
echo; echo "=== reviewed full record with a filled Definition of done hands over the accepted spec ==="
id=full-dod; mkbrief $id; fullrec $id
awk '/^## 11\./{print; getline; print "- The typo in owned.sh usage text is corrected and its regression passes."; next} {print}' "$LAB/data/$id/prep.md" > "$LAB/data/$id/prep.x" && mv "$LAB/data/$id/prep.x" "$LAB/data/$id/prep.md"
spawn $id; review $id; spawn $id
echo; echo "=== surgical certificate (exempt) never carries the overlay ==="
id=cert; mkbrief $id; "${CLEAN[@]}" "$WT/bin/fm-brief.sh" $id --prep --surgical >/dev/null; p="$LAB/data/$id/prep.md"
sed -E -i -e 's/\{Q1\}/no/' -e 's/\{Q2\}/no/' -e 's/\{UI_WIRING\}/no, internal./' -e 's/\{Q[12]_REASON\}/Inspected the helper./' -e 's/\{C[1-5]\}/yes/' -e 's/\{C[1-5]_EVIDENCE\}/bin\/owned.sh:12; rg owned_fn returned only owned.sh; scope excludes data, security, permissions, money, install, server; reproduced; red-first test./' "$p"
spawn $id
