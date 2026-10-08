cleanup_all() {
  local wt pid
  for pid in "$LOCK_CONTENTION_OWNER_PID" "$LOCK_REFUSE_HOLDER_PID" "$LOCK_WAIT_HOLDER_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  LOCK_CONTENTION_OWNER_PID=
  LOCK_REFUSE_HOLDER_PID=
  LOCK_WAIT_HOLDER_PID=
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    "$REAL_TREEHOUSE" return --force "$wt" >/dev/null 2>&1 || true
  done <<EOF
$RECORDED_WORKTREES
EOF
  if [ "$LAB_READY" -eq 1 ]; then
    PATH="$HERDR_ORIGINAL_PATH" \
      "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
    LAB_READY=0
  fi
  # Spawn strips write permission from its private Git-hook directories.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
