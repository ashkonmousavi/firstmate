#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
. bin/backends/herdr.sh
fm_backend_herdr_cli() { local ses=$1; shift; "$ROOT/bin/fm-herdr-lab.sh" run "$ses" "$@"; }
TARGET="fm-lab-ghost-integration:$(cat .phase-lab/herdr-pane)"
actual=$(fm_backend_herdr_composer_state "$TARGET")
echo "Herdr wrapped suggestion verdict=$actual"
test "$actual" = empty
plain=$(fm_backend_herdr_visible_capture "$TARGET")
actual=$(fm_composer_classify_screen $'styled=0\ncursor=0\nidentity=1' "$plain" '' $'claude\tidle')
echo "Herdr unstyled suggestion verdict=$actual"
test "$actual" = unknown
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" 'Reply with exactly HERDR_GHOST_DELIVERED and nothing else.' 3 0.4 0.4)
echo "Herdr real submit after ghost verdict=$verdict"
test "$verdict" = empty
sleep 8
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$E/herdr-after-submit.ansi"
fm_backend_herdr_visible_capture "$TARGET"
