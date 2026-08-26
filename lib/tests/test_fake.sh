#!/usr/bin/env bash
# Fake-capacity testing via f3.

set -euo pipefail

# Run fake-flash test.
# Args: device, mode (quick|full|non-destructive), log_file, status_file, timeout_sec
# Exports via status file keys: claimed_size, real_size, fake_result
# Returns 0 on pass, non-zero on fail.
test_fake() {
  local dev="$1"
  local mode="$2"
  local log="$3"
  local status="$4"
  local tmo="${5:-1800}"

  reporter_set_status "$status" step "f3" progress "0%" speed "--" result "PENDING"

  local out rc=0
  local tmp
  tmp="$(mktemp)"

  if [[ "$mode" == "non-destructive" ]]; then
    local mnt
    mnt="$(mktemp -d /tmp/flash-test-f3.XXXXXX)"
    {
      echo "[f3] non-destructive f3write/f3read on filesystem mount (requires existing fs)"
      # Prefer writing into a temp mount if a partition exists; else use whole-disk probe fallback
      local part=""
      part="$(lsblk -ln -o NAME,TYPE "$dev" | awk '$2=="part"{print "/dev/"$1; exit}')"
      if [[ -z "$part" ]]; then
        echo "[f3] no partition for non-destructive path; falling back to f3probe (read-oriented)"
        timeout "$tmo" f3probe "$dev" 2>&1 || rc=$?
      else
        if mount "$part" "$mnt" 2>>"$log"; then
          timeout "$tmo" f3write "$mnt" 2>&1 || rc=$?
          if [[ $rc -eq 0 ]]; then
            timeout "$tmo" f3read "$mnt" 2>&1 || rc=$?
          fi
          umount "$mnt" 2>>"$log" || true
        else
          echo "[f3] mount failed; running f3probe"
          timeout "$tmo" f3probe "$dev" 2>&1 || rc=$?
        fi
      fi
    } | tee -a "$log" | tee "$tmp"
    rmdir "$mnt" 2>/dev/null || true
  else
    {
      echo "[f3] destructive f3probe on $dev"
      timeout "$tmo" f3probe --destructive --time-ops "$dev" 2>&1 || rc=$?
    } | tee -a "$log" | tee "$tmp"
  fi

  out="$(cat "$tmp")"
  rm -f "$tmp"

  local claimed real
  claimed="$(echo "$out" | grep -iE 'Device size:|Announced:' | head -n1 | grep -oE '[0-9.]+ [GTM]B' | head -n1 || true)"
  real="$(echo "$out" | grep -iE 'Usable:|Exact:|real size' | head -n1 | grep -oE '[0-9.]+ [GTM]B' | head -n1 || true)"
  [[ -z "$claimed" ]] && claimed="$(echo "$out" | grep -oE '[0-9.]+ [GTM]B' | head -n1 || true)"
  [[ -z "$real" ]] && real="unknown"

  # Heuristic: f3probe prints "is a fake" or returns non-zero on bad drives
  if echo "$out" | grep -qiE 'is a fake|Fake flash|damaged'; then
    rc=1
  fi
  # Treat timeout as failure
  if [[ $rc -eq 124 ]]; then
    echo "[f3] FAILED: timeout" | tee -a "$log"
    reporter_set_status "$status" step "f3" progress "100%" result "TIMEOUT" \
      claimed_size "${claimed:-unknown}" real_size "${real:-unknown}"
    return 124
  fi

  if [[ $rc -ne 0 ]]; then
    echo "[f3] FAILED: fake/damaged drive detected (rc=$rc)" | tee -a "$log"
    reporter_set_status "$status" step "f3" progress "100%" result "FAKE" \
      claimed_size "${claimed:-unknown}" real_size "${real:-unknown}"
    return 1
  fi

  echo "[f3] PASSED claimed=${claimed:-unknown} real=${real:-unknown}" | tee -a "$log"
  reporter_set_status "$status" step "f3" progress "100%" result "OK" \
    claimed_size "${claimed:-unknown}" real_size "${real:-unknown}"
  return 0
}
