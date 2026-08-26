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

  # 1) Fake capacity
  _set_step "f3probe"
  if ! f3probe --destructive --time-ops "$resolved"; then
    rc=$?
    echo "error: f3probe failed (rc=$rc)"
    _finish_status "FAILED" "FAKE_OR_F3"
    return "$rc"
  fi

  umount_device_tree "$by_id"
  assert_unmounted "$by_id" || true

  # 2) Bad sectors
  _set_step "badblocks"
  if ! badblocks -wsv "$resolved"; then
    rc=$?
    echo "error: badblocks failed (rc=$rc)"
    _finish_status "FAILED" "BADBLOCKS"
    return "$rc"
  fi

  # 3) SMART (best-effort)
  _set_step "smartctl"
  if ! smartctl -a "$resolved"; then
    echo "[smartctl] unsupported or failed — continuing"
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
