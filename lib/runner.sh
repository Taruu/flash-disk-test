#!/usr/bin/env bash
# Concurrency manager + per-drive pipeline.

set -euo pipefail

FLASH_TEST_CHILD_PIDS=()
FLASH_TEST_ACTIVE_DEVS=()
FLASH_TEST_WRITE_SEM=""
FLASH_TEST_STATUS_FILES=()

# Initialize write-stage semaphore (named pipe token pool).
# Args: max_writers
runner_init_write_sem() {
  local max="${1:-1}"
  FLASH_TEST_WRITE_SEM="$(mktemp -u /tmp/flash-test-wsem.XXXXXX)"
  mkfifo "$FLASH_TEST_WRITE_SEM"
  # Keep FIFO open
  eval "exec ${FLASH_TEST_WRITE_SEM_FD:-9}<> \"$FLASH_TEST_WRITE_SEM\""
  local i
  for ((i = 0; i < max; i++)); do
    echo -n "x" >&9
  done
}

runner_acquire_write() {
  local token
  read -r -n 1 token <&9
}

runner_release_write() {
  echo -n "x" >&9
}

runner_cleanup_sem() {
  if [[ -n "${FLASH_TEST_WRITE_SEM:-}" ]]; then
    exec 9>&- 2>/dev/null || true
    rm -f "$FLASH_TEST_WRITE_SEM" 2>/dev/null || true
    FLASH_TEST_WRITE_SEM=""
  fi
}

# SIGINT/SIGTERM handler
runner_on_signal() {
  echo "" >&2
  echo "[runner] caught signal — stopping workers…" >&2
  local pid dev
  for pid in "${FLASH_TEST_CHILD_PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${FLASH_TEST_CHILD_PIDS[@]:-}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for dev in "${FLASH_TEST_ACTIVE_DEVS[@]:-}"; do
    umount_device_tree "$dev" 2>/dev/null || true
  done
  runner_cleanup_sem
  # Best-effort summary flush
  if ((${#FLASH_TEST_STATUS_FILES[@]})) && [[ -n "${FLASH_TEST_REPORT_DIR:-}" ]]; then
    reporter_write_summary "$FLASH_TEST_REPORT_DIR" "${FLASH_TEST_STATUS_FILES[@]}" 2>/dev/null || true
  fi
  exit 130
}

runner_install_traps() {
  trap runner_on_signal INT TERM
}

# Safe basename for filenames
_safe_id() {
  basename "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Full pipeline for one drive.
# Args: meta_line (by_id|resolved|serial|...), report_dir, mode, format
# Environment: FLASH_TEST_TIMEOUT_* , write sem must be initialized
run_drive_pipeline() {
  local meta="$1"
  local report_dir="$2"
  local mode="$3"
  local format="$4"

  local by_id resolved serial vendor model size_b size_h usb
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb <<<"$meta"

  local ts safe log status json
  ts="$(date +%Y%m%dT%H%M%S)"
  safe="$(_safe_id "$by_id")"
  log="$report_dir/${serial}_${safe}_${ts}.log"
  status="$report_dir/${serial}_${safe}_${ts}.status"
  json="$report_dir/${serial}_${safe}_${ts}.json"

  local t0 t1 dur
  t0="$(date +%s)"

  reporter_init_status "$status" \
    dev "$resolved" serial "$serial" by_id "$by_id" log "$log" \
    status "RUNNING" step "init" result "PENDING"

  {
    echo "=== flash-test pipeline ==="
    echo "by_id=$by_id"
    echo "resolved=$resolved"
    echo "serial=$serial vendor=$vendor model=$model size=$size_h usb=$usb"
    echo "mode=$mode format=$format"
    echo "started=$(date -Iseconds)"
  } >>"$log"

  # Re-validate and unmount
  if ! validate_target_device "$by_id" "${FLASH_TEST_ALLOW_LOOP:-0}"; then
    reporter_set_status "$status" status "FAILED" result "UNSAFE" error "validation failed"
    reporter_write_drive_json "$status" "$json"
    return 1
  fi

  umount_device_tree "$by_id"
  if ! assert_unmounted "$by_id"; then
    # Try once more
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

  # --- Fake (write stage) ---
  runner_acquire_write
  reporter_set_status "$status" status "RUNNING" step "f3"
  if ! test_fake "$by_id" "$mode" "$log" "$status" "$fake_tmo"; then
    rc=$?
    runner_release_write
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi
  runner_release_write

  # --- Surface (write stage for destructive) ---
  runner_acquire_write
  reporter_set_status "$status" step "badblocks"
  if ! test_surface "$by_id" "$mode" "$log" "$status" "$surf_tmo"; then
    rc=$?
    runner_release_write
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi
  runner_release_write

  # --- Speed (write stage) ---
  runner_acquire_write
  reporter_set_status "$status" step "fio"
  if ! test_speed "$by_id" "$mode" "$log" "$status" "$speed_tmo"; then
    rc=$?
    runner_release_write
    reporter_set_status "$status" status "FAILED" result "$(reporter_get "$status" result)"
    t1="$(date +%s)"; dur=$((t1 - t0))
    reporter_set_status "$status" duration_sec "$dur"
    reporter_write_drive_json "$status" "$json"
    return "$rc"
  fi
  runner_release_write

  # --- Format (only on full pass) ---
  if [[ "$format" != "none" ]]; then
    runner_acquire_write
    reporter_set_status "$status" step "format"
    if ! test_format "$by_id" "$format" "$log" "$status" "$fmt_tmo"; then
      rc=$?
      runner_release_write
      reporter_set_status "$status" status "FAILED" result "FORMAT_FAIL"
      t1="$(date +%s)"; dur=$((t1 - t0))
      reporter_set_status "$status" duration_sec "$dur"
      reporter_write_drive_json "$status" "$json"
      return "$rc"
    fi
    runner_release_write
  else
    reporter_set_status "$status" format_outcome "none"
    echo "[format] skipped" | tee -a "$log"
  fi

  t1="$(date +%s)"; dur=$((t1 - t0))
  reporter_set_status "$status" status "FINISHED" step "complete" progress "100%" \
    result "PASSED" duration_sec "$dur"
  echo "[+] SUCCESS: $resolved ($serial) passed in ${dur}s" | tee -a "$log"
  reporter_write_drive_json "$status" "$json"
  return 0
}

# Run pipelines concurrently.
# Args: jobs, write_jobs, report_dir, mode, format, meta_line...
runner_run_batch() {
  local jobs="$1"
  local write_jobs="$2"
  local report_dir="$3"
  local mode="$4"
  local format="$5"
  shift 5
  local metas=("$@")

  FLASH_TEST_REPORT_DIR="$report_dir"
  FLASH_TEST_CHILD_PIDS=()
  FLASH_TEST_ACTIVE_DEVS=()
  FLASH_TEST_STATUS_FILES=()

  mkdir -p "$report_dir"
  runner_init_write_sem "$write_jobs"
  runner_install_traps

  local manifest="$report_dir/manifest.txt"
  : >"$manifest"

  local -a queue=("${metas[@]}")
  local fail_count=0
  local supports_wait_n=1
  if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
    supports_wait_n=0
  fi

  _launch_one() {
    local m="$1"
    local by_id resolved serial
    IFS='|' read -r by_id resolved serial _ <<<"$m"
    FLASH_TEST_ACTIVE_DEVS+=("$by_id")
    (
      run_drive_pipeline "$m" "$report_dir" "$mode" "$format"
    ) &
    local pid=$!
    FLASH_TEST_CHILD_PIDS+=("$pid")
    echo "$pid|$by_id|$serial" >>"$manifest"
  }

  _alive_count() {
    local c=0 p
    for p in "${FLASH_TEST_CHILD_PIDS[@]:-}"; do
      kill -0 "$p" 2>/dev/null && c=$((c + 1))
    done
    echo "$c"
  }

  _reap_finished() {
    local -a still=()
    local p
    for p in "${FLASH_TEST_CHILD_PIDS[@]:-}"; do
      if kill -0 "$p" 2>/dev/null; then
        still+=("$p")
      else
        wait "$p" 2>/dev/null || fail_count=$((fail_count + 1))
      fi
    done
    FLASH_TEST_CHILD_PIDS=("${still[@]}")
  }

  # Fill initial pool
  while ((${#queue[@]} > 0)) && (($(_alive_count) < jobs)); do
    _launch_one "${queue[0]}"
    queue=("${queue[@]:1}")
  done

  while (($(_alive_count) > 0)) || ((${#queue[@]} > 0)); do
    if (($(_alive_count) > 0)); then
      if [[ $supports_wait_n -eq 1 ]]; then
        wait -n 2>/dev/null || fail_count=$((fail_count + 1))
      else
        sleep 0.5
      fi
      _reap_finished
    fi
    while ((${#queue[@]} > 0)) && (($(_alive_count) < jobs)); do
      _launch_one "${queue[0]}"
      queue=("${queue[@]:1}")
    done
  done

  local p
  for p in "${FLASH_TEST_CHILD_PIDS[@]:-}"; do
    wait "$p" 2>/dev/null || fail_count=$((fail_count + 1))
  done
  FLASH_TEST_CHILD_PIDS=()

  mapfile -t FLASH_TEST_STATUS_FILES < <(find "$report_dir" -maxdepth 1 -name '*.status' | sort)
  if ((${#FLASH_TEST_STATUS_FILES[@]})); then
    reporter_write_summary "$report_dir" "${FLASH_TEST_STATUS_FILES[@]}"
  fi

  runner_cleanup_sem
  trap - INT TERM

  if ((fail_count > 0)); then
    return 1
  fi
  return 0
}
