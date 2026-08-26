#!/usr/bin/env bash
# losetup mock harness for single-drive flash-test (requires root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="${MOCK_DIR:-/tmp/flash-test-mocks}"
STATE_FILE="$MOCK_DIR/loops.state"

usage() {
  cat <<'EOF'
mock_loop.sh — create/destroy a loop device for flash-test

Usage:
  sudo ./tests/mock_loop.sh setup [SIZE_MB]     # default 64
  sudo ./tests/mock_loop.sh teardown
  sudo ./tests/mock_loop.sh list
  sudo ./tests/mock_loop.sh run-smoke
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "error: needs root" >&2
    exit 1
  fi
}

cmd_setup() {
  local size_mb="${1:-64}"
  mkdir -p "$MOCK_DIR"
  : >"$STATE_FILE"
  local img loopdev
  img="$MOCK_DIR/mock_drive.img"
  dd if=/dev/zero of="$img" bs=1M count="$size_mb" status=none
  loopdev="$(losetup -f --show "$img")"
  echo "$loopdev $img" >>"$STATE_FILE"
  echo "created $loopdev <- $img (${size_mb}MiB)"
}

cmd_teardown() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "nothing to teardown"
    return 0
  fi
  local loopdev img
  while read -r loopdev img; do
    [[ -z "$loopdev" ]] && continue
    umount "${loopdev}"* 2>/dev/null || true
    losetup -d "$loopdev" 2>/dev/null || true
    rm -f "$img"
    echo "removed $loopdev"
  done <"$STATE_FILE"
  rm -f "$STATE_FILE"
}

cmd_list() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "(no mock loops)"
}

cmd_run_smoke() {
  cmd_setup 64
  local loopdev img
  read -r loopdev img <"$STATE_FILE"
  echo "smoke on $loopdev"
  set +e
  "$ROOT/flash-test" --allow-loop --format none --mode quick \
    --state-file "$MOCK_DIR/selected.conf" \
    --timeout-fake 120 --timeout-surface 300 --timeout-speed 120 \
    "$loopdev"
  local rc=$?
  set -e
  echo "smoke exit=$rc"
  cmd_teardown
  return "$rc"
}

require_root
case "${1:-}" in
  setup) shift; cmd_setup "$@" ;;
  teardown) cmd_teardown ;;
  list) cmd_list ;;
  run-smoke) cmd_run_smoke ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "unknown: $1" >&2; usage; exit 2 ;;
esac
