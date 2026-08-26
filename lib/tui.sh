#!/usr/bin/env bash
# Single-drive TUI: pick one stick, show UUID, confirm format, live progress + log.

set -euo pipefail

tui_hide_cursor() { printf '\033[?25l'; }
tui_show_cursor() { printf '\033[?25h'; }
tui_clear() { printf '\033[2J\033[H'; }
tui_alt_on() { printf '\033[?1049h'; }
tui_alt_off() { printf '\033[?1049l'; }

# ---------------------------------------------------------------------------
# Pick exactly one drive. Prints one metadata line to stdout.
# Restores cursor onto previously saved UUID when still plugged in.
# ---------------------------------------------------------------------------
tui_pick_drive() {
  local allow_loop="${1:-0}"
  local -a metas=()
  local cursor=0
  local i key
  local saved_uuid="" saved_by_id=""

  if [[ ! -t 0 ]] || [[ ! -t 2 ]]; then
    echo "error: interactive mode requires a TTY" >&2
    return 1
  fi

  if selection_load 2>/dev/null; then
    saved_uuid="${SELECTION_UUID:-}"
    saved_by_id="${SELECTION_BY_ID:-}"
  fi

  _reload() {
    metas=()
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      metas+=("$line")
    done < <(enumerate_removable_drives "$allow_loop")

    cursor=0
    if ((${#metas[@]} == 0)); then
      return 0
    fi
    # Prefer previously saved UUID
    if [[ -n "$saved_uuid" || -n "$saved_by_id" ]]; then
      for i in "${!metas[@]}"; do
        local by_id resolved serial vendor model size_b size_h usb uuid
        IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"${metas[$i]}"
        if [[ -n "$saved_uuid" && "$uuid" == "$saved_uuid" ]]; then
          cursor=$i
          return 0
        fi
        if [[ -n "$saved_by_id" && "$by_id" == "$saved_by_id" ]]; then
          cursor=$i
          return 0
        fi
      done
    fi
  }

  _draw() {
    tui_clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  flash-test — Select ONE flash drive                           ║"
    echo "║  j/k move · enter confirm · r refresh · q quit                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    if [[ -n "$saved_uuid" ]]; then
      echo "  Saved UUID: $saved_uuid"
      echo "  State file: $(selection_path)"
      echo ""
    fi
    if ((${#metas[@]} == 0)); then
      echo "  (no removable drives — plug in a stick and press r)"
      echo "  tip: --allow-loop for losetup mocks"
      return 0
    fi
    for i in "${!metas[@]}"; do
      local by_id resolved serial vendor model size_b size_h usb uuid
      IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"${metas[$i]}"
      local prefix="  "
      ((i == cursor)) && prefix="> "
      local mark=" "
      [[ -n "$saved_uuid" && "$uuid" == "$saved_uuid" ]] && mark="*"
      printf '%s%c %-12s  UUID=%-22s  %8s  %-5s  %s\n' \
        "$prefix" "$mark" "$(basename "$resolved")" "$uuid" "$size_h" "$usb" "$model"
    done
    echo ""
    local cur_uuid=""
    if ((${#metas[@]} > 0)); then
      IFS='|' read -r _ _ _ _ _ _ _ _ cur_uuid <<<"${metas[$cursor]}"
    fi
    echo "  Highlighted UUID: ${cur_uuid:-—}"
    echo "  (* = previously saved selection)"
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
        local chosen="${metas[$cursor]}"
        selection_save "$chosen"
        printf '%s\n' "$chosen"
        return 0
        ;;
    esac
  done
}

# Format confirmation for one drive
tui_confirm_format() {
  local fstype="$1"
  local meta="$2"

  if [[ "$fstype" == "none" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    return 0
  fi

  local by_id resolved serial vendor model size_b size_h usb uuid
  IFS='|' read -r by_id resolved serial vendor model size_b size_h usb uuid <<<"$meta"

  print_destructive_banner >&2
  echo "" >&2
  echo "Drive will be FORMATTED as $fstype after tests PASS:" >&2
  echo "  UUID:   $uuid" >&2
  echo "  Device: $resolved" >&2
  echo "  Serial: $serial" >&2
  echo "  Model:  $vendor $model ($size_h)" >&2
  echo "" >&2

  stty echo icanon 2>/dev/null || true
  tui_show_cursor
  local answer
  read -r -p "Type 'yes' to FORMAT this drive after tests pass: " answer
  if [[ "$answer" == "yes" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    echo "Format confirmed for UUID $uuid" >&2
    return 0
  fi

  echo "" >&2
  local cont
  read -r -p "Continue tests WITHOUT formatting? [y/N] " cont
  case "$cont" in
    y|Y|yes|YES)
      FLASH_TEST_FORMAT="none"
      FLASH_TEST_FORMAT_CONFIRMED=1
      FLASH_TEST_FORMAT_OUTCOME_NOTE="skipped_no_confirm"
      echo "Proceeding without format." >&2
      return 0
      ;;
    *)
      echo "Aborted." >&2
      return 1
      ;;
  esac
}

cli_confirm_format() {
  local fstype="$1"
  local yes_format="$2"
  if [[ "$fstype" == "none" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    return 0
  fi
  if [[ "$yes_format" == "1" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    return 0
  fi
  echo "warning: format=$fstype requested but --yes-format not set; skipping format." >&2
  FLASH_TEST_FORMAT="none"
  FLASH_TEST_FORMAT_CONFIRMED=1
  FLASH_TEST_FORMAT_OUTCOME_NOTE="skipped_no_confirm"
  return 0
}

# Live view for a single running pipeline (poll status + tail log).
# Args: report_dir, worker_pid, uuid
tui_live_one() {
  local report_dir="$1"
  local worker_pid="$2"
  local uuid="${3:-}"

  _worker_alive() {
    kill -0 "$worker_pid" 2>/dev/null
  }

  if [[ ! -t 1 ]]; then
    while _worker_alive; do sleep 0.5; done
    return 0
  fi

  tui_alt_on
  tui_hide_cursor
  stty -echo -icanon time 1 min 0 2>/dev/null || true
  trap 'tui_show_cursor; stty echo icanon 2>/dev/null || true; tui_alt_off' EXIT

  local done_shown=0
  while true; do
    local sf log=""
    sf="$(find "$report_dir" -maxdepth 1 -name '*.status' 2>/dev/null | sort | tail -n1 || true)"

    tui_clear
    echo "flash-test — single drive"
    if [[ -n "$uuid" ]]; then
      echo "UUID: $uuid"
    fi
    echo "────────────────────────────────────────────────────────────"
    if [[ -n "$sf" && -f "$sf" ]]; then
      local dev serial st step prog speed result
      dev="$(reporter_get "$sf" dev)"
      serial="$(reporter_get "$sf" serial)"
      st="$(reporter_get "$sf" status)"
      step="$(reporter_get "$sf" step)"
      prog="$(reporter_get "$sf" progress)"
      speed="$(reporter_get "$sf" speed)"
      result="$(reporter_get "$sf" result)"
      log="$(reporter_get "$sf" log)"
      local su
      su="$(grep -E '^uuid=' "$sf" 2>/dev/null | cut -d= -f2- || true)"
      [[ -n "$su" ]] && echo "UUID:    $su"
      echo "Device:  $(basename "${dev:-?}")  ($dev)"
      echo "Serial:  $serial"
      echo "Status:  $st"
      echo "Step:    $step   Progress: $prog"
      echo "Speed:   $speed"
      echo "Result:  $result"
    else
      echo "(starting…)"
    fi
    echo ""
    echo "── log (q detach) ──"
    if [[ -n "$log" && -f "$log" ]]; then
      tail -n 16 "$log" 2>/dev/null || true
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
}
