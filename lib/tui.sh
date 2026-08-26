#!/usr/bin/env bash
# Drive picker + live log tail.

set -euo pipefail

tui_hide_cursor() { printf '\033[?25l'; }
tui_show_cursor() { printf '\033[?25h'; }
tui_clear() { printf '\033[2J\033[H'; }
tui_alt_on() { printf '\033[?1049h'; }
tui_alt_off() { printf '\033[?1049l'; }

# Pick exactly one drive. Prints one metadata line to stdout.
tui_pick_drive() {
  local -a metas=()
  local cursor=0
  local i key

  if [[ ! -t 0 ]] || [[ ! -t 2 ]]; then
    echo "error: interactive mode requires a TTY" >&2
    return 1
  fi

  _reload() {
    metas=()
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      metas+=("$line")
    done < <(enumerate_removable_drives)
    cursor=0
  }

  _draw() {
    tui_clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  flash-test — Select ONE flash drive                           ║"
    echo "║  j/k move · enter confirm · r refresh · q quit                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    if ((${#metas[@]} == 0)); then
      echo "  (no removable drives — plug in a stick and press r)"
      return 0
    fi
    for i in "${!metas[@]}"; do
      local by_id resolved serial vendor model size_b size_h usb uuid
      IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"${metas[$i]}"
      local prefix="  "
      ((i == cursor)) && prefix="> "
      printf '%s %-12s  UUID=%-22s  %8s  %-5s  %s\n' \
        "$prefix" "$(basename "$resolved")" "$uuid" "$size_h" "$usb" "$model"
    done
    echo ""
    local cur_uuid=""
    if ((${#metas[@]} > 0)); then
      IFS='|' read -r _ _ _ _ _ _ _ _ cur_uuid <<<"${metas[$cursor]}"
    fi
    echo "  Highlighted UUID: ${cur_uuid:-—}"
  }

  _reload
  tui_alt_on
  tui_hide_cursor
  stty -echo 2>/dev/null || true
  trap 'tui_show_cursor; stty echo 2>/dev/null || true; tui_alt_off' EXIT

  while true; do
    _draw >&2
    IFS= read -r -n1 key || key="q"
    if [[ "$key" == $'\033' ]]; then
      local r1 r2
      IFS= read -r -n1 -t 0.1 r1 || true
      IFS= read -r -n1 -t 0.1 r2 || true
      if [[ "$r1" == "[" ]]; then
        case "$r2" in
          A) key="k" ;;
          B) key="j" ;;
        esac
      fi
    fi
    case "$key" in
      q|Q)
        tui_show_cursor; stty echo 2>/dev/null || true; tui_alt_off
        trap - EXIT
        return 1
        ;;
      r|R) _reload ;;
      j)
        ((${#metas[@]} > 0)) && cursor=$(( (cursor + 1) % ${#metas[@]} ))
        ;;
      k)
        ((${#metas[@]} > 0)) && cursor=$(( (cursor - 1 + ${#metas[@]} ) % ${#metas[@]} ))
        ;;
      $'\n'|$'\r'|c|C)
        if ((${#metas[@]} == 0)); then
          continue
        fi
        tui_show_cursor; stty echo 2>/dev/null || true; tui_alt_off
        trap - EXIT
        printf '%s\n' "${metas[$cursor]}"
        return 0
        ;;
    esac
  done
}

# Confirm destructive tests. Returns 0 if user typed yes.
tui_confirm_destructive() {
  local meta="$1"
  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  print_destructive_banner >&2
  echo "" >&2
  echo "This will DESTROY all data on:" >&2
  echo "  UUID:   $uuid" >&2
  echo "  Device: $resolved" >&2
  echo "  Serial: $serial" >&2
  echo "  Model:  $vendor $model ($size_h)" >&2
  echo "" >&2
  echo "Pipeline: f3probe → badblocks -w → smartctl → hdparm → mkfs.exfat → fsck" >&2
  echo "" >&2

  stty echo icanon 2>/dev/null || true
  tui_show_cursor
  local answer
  read -r -p "Type 'yes' to START destructive tests: " answer
  [[ "$answer" == "yes" ]]
}

# Confirm format step (second yes). Echoes 1 or 0 to stdout.
tui_confirm_format() {
  local meta="$1"
  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  echo "" >&2
  echo "Reformat as exFAT after tests?" >&2
  echo "  UUID:   $uuid" >&2
  echo "  Device: $resolved" >&2
  echo "" >&2
  stty echo icanon 2>/dev/null || true
  local answer
  read -r -p "Type 'yes' to FORMAT after tests (anything else = skip format): " answer
  if [[ "$answer" == "yes" ]]; then
    echo 1
  else
    echo 0
  fi
}

_step_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# Live view while worker runs.
# Args: worker_pid, step_file, log_file, uuid, device
tui_live_run() {
  local worker_pid="$1"
  local step_file="$2"
  local log_file="$3"
  local uuid="${4:-}"
  local device="${5:-}"

  _worker_alive() {
    kill -0 "$worker_pid" 2>/dev/null
  }

  if [[ ! -t 1 ]]; then
    while _worker_alive; do sleep 0.5; done
    local rc=0
    wait "$worker_pid" 2>/dev/null || rc=$?
    return "$rc"
  fi

  tui_alt_on
  tui_hide_cursor
  stty -echo -icanon time 1 min 0 2>/dev/null || true
  trap 'tui_show_cursor; stty echo icanon 2>/dev/null || true; tui_alt_off' EXIT

  local done_shown=0
  while true; do
    local st step result
    st="$(_step_get "$step_file" status)"
    step="$(_step_get "$step_file" step)"
    result="$(_step_get "$step_file" result)"

    tui_clear
    echo "flash-test — running"
    echo "UUID:    ${uuid:-—}"
    echo "Device:  ${device:-—}"
    echo "Status:  ${st:-RUNNING}"
    echo "Step:    ${step:-…}"
    echo "Result:  ${result:-PENDING}"
    echo "Log:     ${log_file}"
    echo "────────────────────────────────────────────────────────────"
    echo "── log (q detach) ──"
    if [[ -n "$log_file" && -f "$log_file" ]]; then
      tail -n 18 "$log_file" 2>/dev/null || true
    else
      echo "(no log yet)"
    fi

    if ! _worker_alive; then
      if [[ $done_shown -eq 0 ]]; then
        done_shown=1
        echo ""
        echo "══ done — press any key ══"
        stty -echo -icanon time 0 min 1 2>/dev/null || true
        IFS= read -r -n1 _ || true
      fi
      break
    fi

    local key=""
    IFS= read -r -n1 -t 0.5 key || true
    case "$key" in
      q|Q)
        echo "Detached — waiting for test to finish…" >&2
        break
        ;;
    esac
  done

  tui_show_cursor
  stty echo icanon 2>/dev/null || true
  tui_alt_off
  trap - EXIT

  while _worker_alive; do sleep 0.5; done
  local rc=0
  wait "$worker_pid" 2>/dev/null || rc=$?
  return "$rc"
}
