#!/usr/bin/env bash
# Single-drive test pipeline (no concurrency — run one flash-test per stick).

set -euo pipefail

FLASH_TEST_CHILD_PID=""
FLASH_TEST_ACTIVE_DEV=""
FLASH_TEST_STATUS_FILE=""
FLASH_TEST_REPORT_DIR=""

_safe_id() {
  basename "$1" | tr -c 'A-Za-z0-9._-' '_'
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
  exit 130
}

runner_install_traps() {
  trap runner_on_signal INT TERM
}

# Full pipeline for one drive.
# meta: by_id|resolved|serial|vendor|model|size_b|size_h|usb|uuid
# Args: meta, report_dir, mode, format
# Prints status file path on last line to stdout marker? Sets FLASH_TEST_STATUS_FILE.
run_drive_pipeline() {
  local meta="$1"
  local report_dir="$2"
  local mode="$3"
  local format="$4"

  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  local ts safe log status json
  ts="$(date +%Y%m%dT%H%M%S)"
  safe="$(_safe_id "${uuid:-$by_id}")"
  log="$report_dir/${safe}_${ts}.log"
  status="$report_dir/${safe}_${ts}.status"
  json="$report_dir/${safe}_${ts}.json"
  FLASH_TEST_STATUS_FILE="$status"
  FLASH_TEST_ACTIVE_DEV="$by_id"
  FLASH_TEST_REPORT_DIR="$report_dir"

  local t0 t1 dur
  t0="$(date +%s)"

  reporter_init_status "$status" \
    dev "$resolved" serial "$serial" uuid "$uuid" by_id "$by_id" log "$log" \
    status "RUNNING" step "init" result "PENDING"

  {
    echo "=== flash-test (single drive) ==="
    echo "uuid=$uuid"
    echo "by_id=$by_id"
    echo "resolved=$resolved"
    echo "serial=$serial vendor=$vendor model=$model size=$size_h usb=$usb"
    echo "mode=$mode format=$format"
    echo "started=$(date -Iseconds)"
  } >>"$log"

  if ! validate_target_device "$by_id" "${FLASH_TEST_ALLOW_LOOP:-0}"; then
    reporter_set_status "$status" status "FAILED" result "UNSAFE" error "validation failed"
    reporter_write_drive_json "$status" "$json"
    return 1
  fi

  umount_device_tree "$by_id"
  if ! assert_unmounted "$by_id"; then
    umount_device_tree "$by_id"
    if ! assert_unmounted "$by_id"; then
      reporter_set_status "$status" status "FAILED" result "MOUNTED" error "could not unmount"
      reporter_write_drive_json "$status" "$json"
      return 1
    fi
  fi

  local rc=0
  local fake_tmo="${FLASH_TEST_TIMEOUT_FAKE:-1800}"
  local surf_tmo="${FLASH_TEST_TIMEOUT_SURFACE:-21600}"
  local speed_tmo="${FLASH_TEST_TIMEOUT_SPEED:-1800}"
  local fmt_tmo="${FLASH_TEST_TIMEOUT_FORMAT:-600}"

  reporter_set_status "$status" status "RUNNING" step "f3"
  if ! test_fake "$by_id" "$mode" "$log" "$status" "$fake_tmo"; then
    rc=$?
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi

  reporter_set_status "$status" step "badblocks"
  if ! test_surface "$by_id" "$mode" "$log" "$status" "$surf_tmo"; then
    rc=$?
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi

  reporter_set_status "$status" step "fio"
  if ! test_speed "$by_id" "$mode" "$log" "$status" "$speed_tmo"; then
    rc=$?
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi

  if [[ "$format" != "none" ]]; then
    reporter_set_status "$status" step "format"
    if ! test_format "$by_id" "$format" "$log" "$status" "$fmt_tmo"; then
      rc=$?
      reporter_set_status "$status" status "FAILED" result "FORMAT_FAIL"
      t1="$(date +%s)"; dur=$((t1 - t0))
      reporter_set_status "$status" duration_sec "$dur"
      reporter_write_drive_json "$status" "$json"
      return "$rc"
    fi
  else
    reporter_set_status "$status" format_outcome "none"
    echo "[format] skipped" >>"$log"
  fi

  t1="$(date +%s)"; dur=$((t1 - t0))
  reporter_set_status "$status" status "FINISHED" step "complete" progress "100%" \
    result "PASSED" duration_sec "$dur"
  echo "[+] SUCCESS: UUID=$uuid ($resolved) passed in ${dur}s" >>"$log"
  reporter_write_drive_json "$status" "$json"
  return 0
}

# Run one drive (foreground pipeline in a child so TUI can poll).
# Args: meta, report_dir, mode, format
# Sets FLASH_TEST_STATUS_FILE; returns pipeline exit code.
runner_run_one() {
  local meta="$1"
  local report_dir="$2"
  local mode="$3"
  local format="$4"

  mkdir -p "$report_dir"
  runner_install_traps

  # Pre-create a predictable status pointer file for the TUI
  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  run_drive_pipeline "$meta" "$report_dir" "$mode" "$format"
  local rc=$?

  if [[ -n "${FLASH_TEST_STATUS_FILE:-}" && -f "$FLASH_TEST_STATUS_FILE" ]]; then
    reporter_write_summary "$report_dir" "$FLASH_TEST_STATUS_FILE"
  fi

  trap - INT TERM
  return "$rc"
}
