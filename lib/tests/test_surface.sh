#!/usr/bin/env bash
# Surface / integrity scan via badblocks.

set -euo pipefail

# Args: device, mode (quick|full|non-destructive), log, status, timeout
test_surface() {
  local dev="$1"
  local mode="$2"
  local log="$3"
  local status="$4"
  local tmo="${5:-21600}"

  reporter_set_status "$status" step "badblocks" progress "0%" speed "--" result "PENDING"

  local rc=0
  local pattern_args=()
  local rw_args=()

  if [[ "$mode" == "non-destructive" ]]; then
    rw_args=(-n -s -v)
  else
    rw_args=(-w -s -v)
  fi

  if [[ "$mode" == "quick" ]]; then
    # Single custom pattern for speed
    pattern_args=(-t 0xaa)
  elif [[ "$mode" == "full" ]]; then
    # Default badblocks multi-pass patterns (omit -t)
    pattern_args=()
  else
    pattern_args=()
  fi

  echo "[badblocks] starting on $dev mode=$mode" | tee -a "$log"

  # Stream progress: badblocks prints percentage on stderr with -s
  set +e
  timeout "$tmo" badblocks "${rw_args[@]}" "${pattern_args[@]}" "$dev" 2> >(
    tee -a "$log" | while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ([0-9]+(\.[0-9]+)?)% ]]; then
        reporter_set_status "$status" step "badblocks" progress "${BASH_REMATCH[1]}%"
      fi
    done
  )
  rc=$?
  set -e

  if [[ $rc -eq 124 ]]; then
    echo "[badblocks] FAILED: timeout" | tee -a "$log"
    reporter_set_status "$status" step "badblocks" progress "--" result "TIMEOUT"
    return 124
  fi
  if [[ $rc -ne 0 ]]; then
    echo "[badblocks] FAILED: bad blocks or error (rc=$rc)" | tee -a "$log"
    reporter_set_status "$status" step "badblocks" progress "100%" result "BAD_BLOCKS"
    return 1
  fi

  echo "[badblocks] PASSED" | tee -a "$log"
  reporter_set_status "$status" step "badblocks" progress "100%" result "OK"
  return 0
}
