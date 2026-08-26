#!/usr/bin/env bash
# losetup mock harness for flash-test (requires root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="${MOCK_DIR:-/tmp/flash-test-mocks}"
STATE_FILE="$MOCK_DIR/loops.state"

usage() {
  cat <<'EOF'
mock_loop.sh — create/destroy loop devices for flash-test dry runs

Usage:
  sudo ./tests/mock_loop.sh setup [N] [SIZE_MB]   # default N=2 SIZE_MB=64
  sudo ./tests/mock_loop.sh teardown
  sudo ./tests/mock_loop.sh list
  sudo ./tests/mock_loop.sh fault-ro LOOPDEV       # make read-only
  sudo ./tests/mock_loop.sh run-smoke             # setup + flash-test --allow-loop

Examples:
  sudo ./tests/mock_loop.sh setup 2 64
  sudo ./flash-test --allow-loop --format none --yes-format \
       --jobs 2 --mode quick /dev/loopX /dev/loopY
  sudo ./tests/mock_loop.sh teardown
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "error: mock_loop.sh needs root" >&2
    exit 1
  fi
}

cmd_setup() {
  local n="${1:-2}"
  local size_mb="${2:-64}"
  mkdir -p "$MOCK_DIR"
  : >"$STATE_FILE"
  local i img loopdev
  for ((i = 1; i <= n; i++)); do
    img="$MOCK_DIR/mock_drive${i}.img"
    dd if=/dev/zero of="$img" bs=1M count="$size_mb" status=none
    loopdev="$(losetup -f --show "$img")"
    echo "$loopdev $img" >>"$STATE_FILE"
    echo "created $loopdev <- $img (${size_mb}MiB)"
  done
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
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "(no mock loops)"
    return 0
  fi
  cat "$STATE_FILE"
}

cmd_fault_ro() {
  local loopdev="$1"
  blockdev --setro "$loopdev"
  echo "set read-only: $loopdev"
}

cmd_run_smoke() {
  cmd_setup 2 64
  local -a loops=()
  local loopdev img
  while read -r loopdev img; do
    loops+=("$loopdev")
  done <"$STATE_FILE"
  echo "Running smoke test on: ${loops[*]}"
  # Short timeouts; format none; skip heavy stages by using tiny images
  # Note: f3probe/badblocks/fio on 64M loops — may still take a bit
  set +e
  "$ROOT/flash-test" --allow-loop --format none --mode quick --jobs 2 \
    --timeout-fake 120 --timeout-surface 300 --timeout-speed 120 \
    "${loops[@]}"
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
  fault-ro) cmd_fault_ro "${2:?loop device required}" ;;
  run-smoke) cmd_run_smoke ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "unknown: $1" >&2; usage; exit 2 ;;
esac
