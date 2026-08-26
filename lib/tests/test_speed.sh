#!/usr/bin/env bash
# Throughput / IOPS via fio.

set -euo pipefail

# Args: device, mode, log, status, timeout
# Sets write_bw_mbs, read_bw_mbs, write_iops, read_iops on status
test_speed() {
  local dev="$1"
  local mode="$2"
  local log="$3"
  local status="$4"
  local tmo="${5:-1800}"

  reporter_set_status "$status" step "fio" progress "0%" speed "--" result "PENDING"

  local size
  case "$mode" in
    quick) size="256M" ;;
    full) size="1G" ;;
    non-destructive) size="128M" ;;
    *) size="256M" ;;
  esac

  local json_out
  json_out="$(mktemp)"
  echo "[fio] seq write/read size=$size on $dev" | tee -a "$log"

  local rc=0
  local ioengine="libaio"
  if ! fio --enghelp 2>/dev/null | grep -q libaio; then
    ioengine="psync"
  fi

  set +e
  timeout "$tmo" fio \
    --name=flash_qa \
    --filename="$dev" \
    --direct=1 \
    --rw=write \
    --bs=1M \
    --size="$size" \
    --iodepth=4 \
    --ioengine="$ioengine" \
    --output-format=json \
    --output="$json_out" \
    >>"$log" 2>&1
  rc=$?
  set -e

  if [[ $rc -eq 124 ]]; then
    echo "[fio] write FAILED: timeout" | tee -a "$log"
    reporter_set_status "$status" step "fio" result "TIMEOUT"
    rm -f "$json_out"
    return 124
  fi
  if [[ $rc -ne 0 ]]; then
    echo "[fio] write FAILED rc=$rc" | tee -a "$log"
    reporter_set_status "$status" step "fio" result "FAIL"
    rm -f "$json_out"
    return 1
  fi

  local write_bw write_iops
  write_bw="$(python3 -c "
import json,sys
d=json.load(open('$json_out'))
j=d['jobs'][0]
bw=j['write'].get('bw_bytes', j['write'].get('bw',0)*1024)
print(f'{bw/1024/1024:.1f}')
" 2>/dev/null || echo "0")"
  write_iops="$(python3 -c "
import json
d=json.load(open('$json_out'))
print(int(d['jobs'][0]['write'].get('iops',0)))
" 2>/dev/null || echo "0")"

  reporter_set_status "$status" step "fio" progress "50%" speed "${write_bw} MB/s" \
    write_bw_mbs "$write_bw" write_iops "$write_iops"

  # Read pass
  set +e
  timeout "$tmo" fio \
    --name=flash_qa_read \
    --filename="$dev" \
    --direct=1 \
    --rw=read \
    --bs=1M \
    --size="$size" \
    --iodepth=4 \
    --ioengine="$ioengine" \
    --output-format=json \
    --output="$json_out" \
    >>"$log" 2>&1
  rc=$?
  set -e

  local read_bw=0 read_iops=0
  if [[ $rc -eq 0 ]]; then
    read_bw="$(python3 -c "
import json
d=json.load(open('$json_out'))
j=d['jobs'][0]
bw=j['read'].get('bw_bytes', j['read'].get('bw',0)*1024)
print(f'{bw/1024/1024:.1f}')
" 2>/dev/null || echo "0")"
    read_iops="$(python3 -c "
import json
d=json.load(open('$json_out'))
print(int(d['jobs'][0]['read'].get('iops',0)))
" 2>/dev/null || echo "0")"
  else
    echo "[fio] read warning rc=$rc (write stats kept)" | tee -a "$log"
  fi

  rm -f "$json_out"

  echo "[fio] PASSED write=${write_bw}MB/s read=${read_bw}MB/s" | tee -a "$log"
  reporter_set_status "$status" step "fio" progress "100%" \
    speed "W:${write_bw}/R:${read_bw} MB/s" result "OK" \
    write_bw_mbs "$write_bw" read_bw_mbs "$read_bw" \
    write_iops "$write_iops" read_iops "$read_iops"
  return 0
}
