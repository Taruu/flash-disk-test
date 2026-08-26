#!/usr/bin/env bash
# Fixed destructive pipeline; all output teed to logs/<uuid>/<ts>.log

set -euo pipefail

FLASH_TEST_CHILD_PID=""
FLASH_TEST_ACTIVE_DEV=""
FLASH_TEST_LOG=""
FLASH_TEST_STEP_FILE=""
FLASH_TEST_RESULT="PENDING"

_safe_id() {
  basename "$1" | tr -c 'A-Za-z0-9._-' '_'
}

_set_step() {
  local step="$1"
  if [[ -n "${FLASH_TEST_STEP_FILE:-}" ]]; then
    printf 'step=%s\nstatus=RUNNING\nresult=%s\nlog=%s\n' \
      "$step" "${FLASH_TEST_RESULT}" "${FLASH_TEST_LOG:-}" \
      >"${FLASH_TEST_STEP_FILE}.tmp"
    mv -f "${FLASH_TEST_STEP_FILE}.tmp" "$FLASH_TEST_STEP_FILE"
  fi
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo ">>> STEP: $step"
  echo "════════════════════════════════════════════════════════════"
}

_finish_status() {
  local status="$1" result="$2"
  FLASH_TEST_RESULT="$result"
  if [[ -n "${FLASH_TEST_STEP_FILE:-}" ]]; then
    local step
    step="$(grep -E '^step=' "$FLASH_TEST_STEP_FILE" 2>/dev/null | cut -d= -f2- || echo done)"
    printf 'step=%s\nstatus=%s\nresult=%s\nlog=%s\n' \
      "$step" "$status" "$result" "${FLASH_TEST_LOG:-}" \
      >"${FLASH_TEST_STEP_FILE}.tmp"
    mv -f "${FLASH_TEST_STEP_FILE}.tmp" "$FLASH_TEST_STEP_FILE"
  fi
}

runner_on_signal() {
  echo "" >&2
  echo "[runner] caught signal — stopping…" >&2
  if [[ -n "${FLASH_TEST_CHILD_PID:-}" ]]; then
    kill -TERM "$FLASH_TEST_CHILD_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$FLASH_TEST_CHILD_PID" 2>/dev/null || true
  fi
  if [[ -n "${FLASH_TEST_ACTIVE_DEV:-}" ]]; then
    umount_device_tree "$FLASH_TEST_ACTIVE_DEV" 2>/dev/null || true
  fi
  _finish_status "FAILED" "ABORTED"
  exit 130
}

# Log path helpers (also used by TUI / entrypoint)
prepare_log_paths() {
  local uuid="$1"
  local root="${FLASH_TEST_ROOT:-.}"
  local safe ts dir
  safe="$(_safe_id "$uuid")"
  ts="$(date +%Y%m%dT%H%M%S)"
  dir="$root/logs/$safe"
  mkdir -p "$dir"
  FLASH_TEST_LOG="$dir/${ts}.log"
  FLASH_TEST_STEP_FILE="$dir/${ts}.step"
  printf '%s\n' "$FLASH_TEST_LOG"
}

smart_state_path() {
  local uuid="$1"
  local root="${FLASH_TEST_ROOT:-.}"
  local safe
  safe="$(_safe_id "$uuid")"
  mkdir -p "$root/logs/$safe"
  echo "$root/logs/$safe/smart-selftest.state"
}

# Returns 0 if drive answers SMART queries.
smart_available() {
  local dev="$1"
  local out
  out="$(smartctl -i "$dev" 2>&1 || true)"
  if echo "$out" | grep -qiE 'SMART support is:[[:space:]]*(Available|Enabled)'; then
    return 0
  fi
  # USB bridges sometimes omit that line but still answer -H/-a
  if smartctl -H "$dev" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Returns 0 if offline/conveyance/short/long self-test looks available.
smart_selftest_supported() {
  local dev="$1"
  local caps
  caps="$(smartctl -c "$dev" 2>/dev/null || true)"
  if echo "$caps" | grep -qiE 'Self-test[[:space:]].*(available|supported)|Selective self-test|Short self-test|Extended self-test'; then
    return 0
  fi
  # Fallback: try dry capability via -t options in help text is useless; probe -l selftest
  if smartctl -l selftest "$dev" >/dev/null 2>&1; then
    # Have a log page — often implies self-test capability even if -c is sparse
    if echo "$caps" | grep -qiE 'Offline data collection|Self-test execution status'; then
      return 0
    fi
  fi
  return 1
}

# Returns 0 if a self-test is currently running on the drive.
smart_selftest_in_progress() {
  local dev="$1"
  local info
  info="$(smartctl -c "$dev" 2>/dev/null || smartctl -a "$dev" 2>/dev/null || true)"
  echo "$info" | grep -qiE 'Self-test execution status:.*in progress|[0-9]+% of test remaining'
}

smart_selftest_progress_line() {
  local dev="$1"
  smartctl -c "$dev" 2>/dev/null | grep -iE 'Self-test execution status' | head -n1 || \
    smartctl -a "$dev" 2>/dev/null | grep -iE 'Self-test execution status' | head -n1 || \
    echo "(no progress line)"
}

smart_save_selftest_state() {
  local uuid="$1" dev="$2" test="${3:-long}"
  local path
  path="$(smart_state_path "$uuid")"
  cat >"$path" <<EOF
uuid=$uuid
dev=$dev
test=$test
started_at=$(date -Iseconds)
EOF
}

smart_clear_selftest_state() {
  local uuid="$1"
  rm -f "$(smart_state_path "$uuid")"
}

smart_has_selftest_state() {
  local uuid="$1"
  [[ -f "$(smart_state_path "$uuid")" ]]
}

# Dump smartctl -a (best-effort). Returns 0 always; prints "unsupported" on failure.
smart_dump_all() {
  local dev="$1"
  local rc=0
  echo "[smartctl] smartctl -a $dev"
  smartctl -a "$dev" || rc=$?
  # smartctl exit codes are bitflags; bits 0–1 mean CLI/open failure
  if (( (rc & 3) != 0 )); then
    echo "[smartctl] unsupported or failed (rc=$rc) — continuing"
  elif (( rc != 0 )); then
    echo "[smartctl] completed with status bits rc=$rc — continuing"
  fi
  return 0
}

# Start offline self-test (firmware runs it; smartctl returns after arming).
# test: short|long (default long)
smart_start_selftest() {
  local dev="$1"
  local test="${2:-long}"
  local rc=0
  echo "[smartctl] starting offline self-test: smartctl -t $test $dev"
  smartctl -t "$test" "$dev" || rc=$?
  if (( (rc & 3) != 0 )); then
    echo "[smartctl] failed to start self-test (rc=$rc)"
    return 1
  fi
  if (( rc != 0 )); then
    echo "[smartctl] self-test armed with status bits rc=$rc"
  fi
  return 0
}

# Interactive SMART gate before destructive tests.
# Prints to stderr for UI; may write a small smart log under logs/<uuid>/.
# Return codes for caller:
#   0  — continue with destructive pipeline
#   10 — self-test started; exit the app
#   11 — self-test still running; exit the app
smart_preflight() {
  local meta="$1"
  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  local root="${FLASH_TEST_ROOT:-.}"
  local safe log
  safe="$(_safe_id "$uuid")"
  mkdir -p "$root/logs/$safe"
  log="$root/logs/$safe/smart-$(date +%Y%m%dT%H%M%S).log"

  {
    echo "=== SMART preflight ==="
    echo "uuid=$uuid resolved=$resolved"
    echo "started=$(date -Iseconds)"
    echo ""
  } | tee -a "$log" >&2

  # Always attempt identity / health dump first
  {
    if ! smart_available "$resolved"; then
      echo "[smartctl] unsupported — skipping self-test gate"
      echo "[smartctl] unsupported — continuing"
    else
      smart_dump_all "$resolved"
    fi
  } 2>&1 | tee -a "$log" >&2

  if ! smart_available "$resolved"; then
    return 0
  fi

  # Pending self-test from a previous run?
  if smart_has_selftest_state "$uuid"; then
    echo "" >&2
    echo "[smartctl] Found pending self-test state for UUID $uuid" >&2
    if smart_selftest_in_progress "$resolved"; then
      echo "[smartctl] Self-test still running:" >&2
      smart_selftest_progress_line "$resolved" >&2
      echo "" >&2
      echo "Re-run flash-test later to read the result, then continue destructive tests." >&2
      echo "SMART log: $log" >&2
      return 11
    fi

    echo "[smartctl] Self-test finished — latest log:" >&2
    {
      echo "--- smartctl -l selftest ---"
      smartctl -l selftest "$resolved" || echo "[smartctl] could not read self-test log"
      echo "--- smartctl -H ---"
      smartctl -H "$resolved" || true
    } 2>&1 | tee -a "$log" >&2
    smart_clear_selftest_state "$uuid"
    echo "" >&2
    echo "[smartctl] Cleared pending state. Continuing to destructive tests." >&2
    echo "SMART log: $log" >&2
    return 0
  fi

  if ! smart_selftest_supported "$resolved"; then
    echo "[smartctl] Self-test not available on this disk — continuing" >&2
    echo "SMART log: $log" >&2
    return 0
  fi

  echo "" >&2
  echo "[smartctl] This disk supports SMART self-tests." >&2
  echo "  A long offline self-test runs on the drive firmware (can take hours)." >&2
  echo "  flash-test will start it and exit; re-run later to see the result." >&2
  echo "" >&2
  stty echo icanon 2>/dev/null || true
  local answer
  read -r -p "Type 'yes' to start SMART long self-test and EXIT (anything else = skip): " answer
  if [[ "$answer" != "yes" ]]; then
    echo "[smartctl] Self-test skipped — continuing" >&2
    echo "SMART log: $log" >&2
    return 0
  fi

  local start_log
  start_log="$(mktemp)"
  set +e
  smart_start_selftest "$resolved" long >"$start_log" 2>&1
  local start_rc=$?
  set -e
  tee -a "$log" <"$start_log" >&2
  rm -f "$start_log"

  if [[ $start_rc -ne 0 ]]; then
    echo "[smartctl] Self-test not started — continuing" >&2
    echo "SMART log: $log" >&2
    return 0
  fi

  smart_save_selftest_state "$uuid" "$resolved" long
  echo "" >&2
  echo "[smartctl] Self-test armed. State: $(smart_state_path "$uuid")" >&2
  echo "Leave the drive plugged in. Re-run: sudo ./flash-test" >&2
  echo "SMART log: $log" >&2
  return 10
}

# Run the full pipeline for one drive metadata line.
# meta: by_id|resolved|serial|vendor|model|size_b|size_h|usb|uuid
# do_format: 0|1
# All stdout/stderr of this function should be teed by the caller, OR we tee
# internally when FLASH_TEST_LOG is set.
run_drive_pipeline() {
  local meta="$1"
  local do_format="${2:-1}"

  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  FLASH_TEST_ACTIVE_DEV="$by_id"
  FLASH_TEST_RESULT="PENDING"
  trap runner_on_signal INT TERM

  {
    echo "=== flash-test (simple one-drive) ==="
    echo "uuid=$uuid"
    echo "by_id=$by_id"
    echo "resolved=$resolved"
    echo "serial=$serial vendor=$vendor model=$model size=$size_h usb=$usb"
    echo "format=$do_format"
    echo "started=$(date -Iseconds)"
    echo ""
  }

  if ! validate_target_device "$by_id"; then
    echo "error: validation failed"
    _finish_status "FAILED" "UNSAFE"
    return 1
  fi

  umount_device_tree "$by_id"
  if ! assert_unmounted "$by_id"; then
    umount_device_tree "$by_id"
    if ! assert_unmounted "$by_id"; then
      echo "error: could not unmount"
      _finish_status "FAILED" "MOUNTED"
      return 1
    fi
  fi

  local rc=0

  # 1) SMART health dump (best-effort; before destructive fake probe)
  _set_step "smartctl"
  smart_dump_all "$resolved"

  # 2) Fake capacity
  _set_step "f3probe"
  if ! f3probe --destructive --time-ops "$resolved"; then
    rc=$?
    echo "error: f3probe failed (rc=$rc)"
    _finish_status "FAILED" "FAKE_OR_F3"
    return "$rc"
  fi

  umount_device_tree "$by_id"
  assert_unmounted "$by_id" || true

  # 3) Bad sectors
  _set_step "badblocks"
  if ! badblocks -wsv "$resolved"; then
    rc=$?
    echo "error: badblocks failed (rc=$rc)"
    _finish_status "FAILED" "BADBLOCKS"
    return "$rc"
  fi

  # 4) Speed
  _set_step "hdparm"
  if ! hdparm -Tt "$resolved"; then
    echo "[hdparm] failed — continuing"
  fi

  # 5) Reformat + fsck
  if [[ "$do_format" == "1" ]]; then
    _set_step "format"
    umount_device_tree "$by_id"
    if ! assert_unmounted "$by_id"; then
      echo "error: could not unmount before format"
      _finish_status "FAILED" "MOUNTED"
      return 1
    fi

    echo "[format] wipefs -a $resolved"
    wipefs -a "$resolved"

    echo "[format] parted: mklabel msdos + primary partition"
    parted -s "$resolved" mklabel msdos
    parted -s "$resolved" mkpart primary 1MiB 100%
    udevadm settle 2>/dev/null || sleep 1

    local part=""
    part="$(lsblk -ln -o NAME,TYPE "$resolved" | awk '$2=="part"{print "/dev/"$1; exit}')"
    if [[ -z "$part" ]]; then
      # nvme/mmc naming fallback
      if [[ -b "${resolved}1" ]]; then
        part="${resolved}1"
      elif [[ -b "${resolved}p1" ]]; then
        part="${resolved}p1"
      fi
    fi
    if [[ -z "$part" || ! -b "$part" ]]; then
      echo "error: could not find new partition on $resolved"
      _finish_status "FAILED" "FORMAT"
      return 1
    fi

    echo "[format] mkfs.exfat $part"
    mkfs.exfat "$part"

    _set_step "fsck"
    echo "[fsck] fsck.exfat -v $part"
    if ! fsck.exfat -v "$part"; then
      rc=$?
      echo "error: fsck.exfat failed (rc=$rc)"
      _finish_status "FAILED" "FSCK"
      return "$rc"
    fi
  else
    echo "[format] skipped"
  fi

  echo ""
  echo "=== finished=$(date -Iseconds) result=PASS ==="
  _finish_status "DONE" "PASS"
  return 0
}

# Background worker: run pipeline with tee to log.
# Sets FLASH_TEST_LOG / FLASH_TEST_STEP_FILE; prints worker PID on stdout last? 
# Caller should: start_pipeline_bg meta do_format  → sets FLASH_TEST_CHILD_PID
start_pipeline_bg() {
  local meta="$1"
  local do_format="${2:-1}"
  local uuid
  uuid="$(awk -F'|' '{print $9}' <<<"$meta")"

  prepare_log_paths "$uuid" >/dev/null
  printf 'step=init\nstatus=RUNNING\nresult=PENDING\nlog=%s\n' "$FLASH_TEST_LOG" \
    >"$FLASH_TEST_STEP_FILE"

  (
    # shellcheck disable=SC2030
    run_drive_pipeline "$meta" "$do_format" 2>&1 | tee -a "$FLASH_TEST_LOG"
    exit "${PIPESTATUS[0]}"
  ) &
  FLASH_TEST_CHILD_PID=$!
}
