#!/usr/bin/env bash
# Status file protocol + CSV/JSON summary writers.

set -euo pipefail

# Status files are key=value lines, atomically rewritten.
reporter_init_status() {
  local status_file="$1"
  shift
  {
    echo "status=PENDING"
    echo "step=init"
    echo "progress=--"
    echo "speed=--"
    echo "result=PENDING"
    echo "claimed_size="
    echo "real_size="
    echo "write_bw_mbs="
    echo "read_bw_mbs="
    echo "write_iops="
    echo "read_iops="
    echo "format_outcome="
    echo "duration_sec="
    echo "dev="
    echo "serial="
    echo "uuid="
    echo "by_id="
    echo "log="
    echo "error="
    while (( $# >= 2 )); do
      printf '%s=%s\n' "$1" "$2"
      shift 2
    done
  } >"${status_file}.tmp"
  mv -f "${status_file}.tmp" "$status_file"
}

# reporter_set_status file key val [key val ...]
reporter_set_status() {
  local status_file="$1"
  shift
  local -A kv=()
  local k v line
  if [[ -f "$status_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" != *=* ]] && continue
      k="${line%%=*}"
      v="${line#*=}"
      kv["$k"]="$v"
    done <"$status_file"
  fi
  while (( $# >= 2 )); do
    kv["$1"]="$2"
    shift 2
  done
  {
    for k in status step progress speed result claimed_size real_size \
             write_bw_mbs read_bw_mbs write_iops read_iops format_outcome \
             duration_sec dev serial uuid by_id log error; do
      printf '%s=%s\n' "$k" "${kv[$k]:-}"
    done
  } >"${status_file}.tmp"
  mv -f "${status_file}.tmp" "$status_file"
}

reporter_get() {
  local status_file="$1" key="$2"
  [[ -f "$status_file" ]] || { echo ""; return 0; }
  grep -E "^${key}=" "$status_file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# Escape JSON string
_json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "${1//\"/\\\"}"
}

# Write per-drive JSON from status file
reporter_write_drive_json() {
  local status_file="$1"
  local json_file="$2"
  python3 - "$status_file" "$json_file" <<'PY'
import sys
path, out = sys.argv[1], sys.argv[2]
data = {}
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k] = v
import json
with open(out, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Write batch summary.json and summary.csv from a list of status files
# Args: report_dir, status_file...
reporter_write_summary() {
  local report_dir="$1"
  shift
  local csv="$report_dir/summary.csv"
  local json="$report_dir/summary.json"
  local status_files=("$@")

  {
    echo "dev,serial,by_id,status,result,claimed_size,real_size,write_bw_mbs,read_bw_mbs,format_outcome,duration_sec,log"
    local sf
    for sf in "${status_files[@]}"; do
      [[ -f "$sf" ]] || continue
      python3 - "$sf" <<'PY'
import sys, csv
path = sys.argv[1]
d = {}
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if "=" not in line: continue
        k, v = line.split("=", 1)
        d[k] = v
fields = ["dev","serial","by_id","status","result","claimed_size","real_size",
          "write_bw_mbs","read_bw_mbs","format_outcome","duration_sec","log"]
import io
buf = io.StringIO()
w = csv.writer(buf)
w.writerow([d.get(k, "") for k in fields])
sys.stdout.write(buf.getvalue())
PY
    done
  } >"$csv"

  python3 - "$json" "${status_files[@]}" <<'PY'
import sys, json
out = sys.argv[1]
files = sys.argv[2:]
drives = []
for path in files:
    try:
        d = {}
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" not in line: continue
                k, v = line.split("=", 1)
                d[k] = v
        drives.append(d)
    except FileNotFoundError:
        pass
passed = sum(1 for d in drives if d.get("result") == "PASSED")
failed = sum(1 for d in drives if d.get("status") == "FAILED" or d.get("result") not in ("PASSED", "PENDING", ""))
summary = {
    "drive_count": len(drives),
    "passed": passed,
    "failed": len(drives) - passed,
    "drives": drives,
}
with open(out, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY
}
