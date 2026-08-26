#!/usr/bin/env bash
# Post-test provisioning: wipefs + parted + mkfs.

set -euo pipefail

# Args: device, fstype (exfat|vfat|ext4|none), log, status, timeout
test_format() {
  local dev="$1"
  local fstype="$2"
  local log="$3"
  local status="$4"
  local tmo="${5:-600}"

  if [[ "$fstype" == "none" ]]; then
    echo "[format] skipped (format=none)" | tee -a "$log"
    reporter_set_status "$status" step "format" progress "100%" result "SKIPPED"
    return 0
  fi

  reporter_set_status "$status" step "format" progress "0%" result "PENDING"
  echo "[format] wipefs + parted + mkfs.$fstype on $dev" | tee -a "$log"

  local rc=0
  set +e
  timeout "$tmo" bash -c "
    set -e
    wipefs -a '$dev'
    parted -s '$dev' mklabel msdos mkpart primary 1MiB 100%
    partprobe '$dev' 2>/dev/null || true
    sleep 1
    # Resolve first partition (sdX1, nvme0n1p1, loop0p1, …)
    part=''
    for cand in '${dev}1' '${dev}p1'; do
      if [[ -b \"\$cand\" ]]; then part=\"\$cand\"; break; fi
    done
    if [[ -z \"\$part\" ]]; then
      # by-id partition link
      base=\$(basename '$dev')
      for cand in /dev/disk/by-id/\${base}-part1; do
        if [[ -e \"\$cand\" ]]; then part=\"\$cand\"; break; fi
      done
    fi
    if [[ -z \"\$part\" ]]; then
      echo 'error: partition not found after parted' >&2
      exit 1
    fi
    case '$fstype' in
      exfat) mkfs.exfat -n FLASHQA \"\$part\" ;;
      vfat|fat32) mkfs.vfat -F 32 -n FLASHQA \"\$part\" ;;
      ext4) mkfs.ext4 -F -L FLASHQA \"\$part\" ;;
      *) echo \"error: unknown fstype $fstype\" >&2; exit 1 ;;
    esac
  " >>"$log" 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 124 ]]; then
    echo "[format] FAILED: timeout" | tee -a "$log"
    reporter_set_status "$status" step "format" result "TIMEOUT"
    return 124
  fi
  if [[ $rc -ne 0 ]]; then
    echo "[format] FAILED rc=$rc" | tee -a "$log"
    reporter_set_status "$status" step "format" result "FAIL"
    return 1
  fi

  echo "[format] PASSED ($fstype)" | tee -a "$log"
  reporter_set_status "$status" step "format" progress "100%" result "OK" format_outcome "$fstype"
  return 0
}
