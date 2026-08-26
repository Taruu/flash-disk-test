#!/usr/bin/env bash
# Interactive TUI: drive picker, format confirmation, live progress + logs.

set -euo pipefail

tui_hide_cursor() { printf '\033[?25l'; }
tui_show_cursor() { printf '\033[?25h'; }
tui_clear() { printf '\033[2J\033[H'; }
tui_alt_on() { printf '\033[?1049h'; }
tui_alt_off() { printf '\033[?1049l'; }

# ---------------------------------------------------------------------------
# Drive picker
# Args: allow_loop
# Prints selected metadata lines to stdout; returns 0 on confirm, 1 on quit.
# ---------------------------------------------------------------------------
tui_pick_drives() {
  local allow_loop="${1:-0}"
  local -a metas=()
  local -a selected=()
  local cursor=0
  local i key

  if [[ ! -t 0 ]] || [[ ! -t 2 ]]; then
    echo "error: --interactive requires a TTY" >&2
    return 1
  fi

  _reload() {
    metas=()
    selected=()
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      metas+=("$line")
      selected+=(0)
    done < <(enumerate_removable_drives "$allow_loop")
    if ((cursor >= ${#metas[@]} && ${#metas[@]} > 0)); then
      cursor=$((${#metas[@]} - 1))
    fi
    ((${#metas[@]} == 0)) && cursor=0
  }

  _draw() {
    tui_clear
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  flash-test — Select drives                                    ║"
    echo "║  j/k or arrows move · space toggle · a all · r refresh         ║"
    echo "║  enter or c confirm · q quit                                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    if ((${#metas[@]} == 0)); then
      echo "  (no removable drives found — plug in a stick and press r)"
      echo "  tip: use --allow-loop for losetup mock devices"
    else
      for i in "${!metas[@]}"; do
        local by_id resolved serial vendor model size_b size_h usb
        IFS='|' read -r by_id resolved serial vendor model size_b size_h usb <<<"${metas[$i]}"
        local mark=" "
        [[ "${selected[$i]}" == "1" ]] && mark="x"
        local prefix="  "
        ((i == cursor)) && prefix="> "
        printf '%s[%s] %-14s  %-18s  %8s  %-6s  %s %s\n' \
          "$prefix" "$mark" "$(basename "$resolved")" "$serial" "$size_h" "$usb" "$vendor" "$model"
      done
    fi
    local nsel=0
    for i in "${!selected[@]}"; do
      [[ "${selected[$i]}" == "1" ]] && nsel=$((nsel + 1))
    done
    echo ""
    echo "  Selected: $nsel / ${#metas[@]}"
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
      a|A)
        local all_on=1
        for i in "${!selected[@]}"; do
          [[ "${selected[$i]}" == "0" ]] && all_on=0 && break
        done
        for i in "${!selected[@]}"; do
          selected[$i]=$((1 - all_on))
        done
        ;;
      " ")
        if ((${#metas[@]} > 0)); then
          selected[$cursor]=$((1 - selected[$cursor]))
        fi
        ;;
      j)
        ((${#metas[@]} > 0)) && cursor=$(( (cursor + 1) % ${#metas[@]} ))
        ;;
      k)
        ((${#metas[@]} > 0)) && cursor=$(( (cursor - 1 + ${#metas[@]} ) % ${#metas[@]} ))
        ;;
      c|C|$'\n'|$'\r')
        local any=0
        for i in "${!selected[@]}"; do
          [[ "${selected[$i]}" == "1" ]] && any=1 && break
        done
        if [[ $any -eq 0 ]]; then
          continue
        fi
        tui_show_cursor; stty echo 2>/dev/null || true; tui_alt_off
        trap - EXIT
        for i in "${!selected[@]}"; do
          [[ "${selected[$i]}" == "1" ]] && printf '%s\n' "${metas[$i]}"
        done
        return 0
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Format confirmation gate
# ---------------------------------------------------------------------------
tui_confirm_format() {
  local fstype="$1"
  shift
  local -a metas=("$@")

  if [[ "$fstype" == "none" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    return 0
  fi

  print_destructive_banner >&2
  echo "" >&2
  echo "The following drives will be FORMATTED as $fstype after tests PASS:" >&2
  echo "" >&2
  local i=1 meta by_id resolved serial vendor model size_b size_h usb
  for meta in "${metas[@]}"; do
    IFS='|' read -r by_id resolved serial vendor model size_b size_h usb <<<"$meta"
    printf '  %2d. %s  serial=%s  size=%s  %s %s\n' \
      "$i" "$resolved" "$serial" "$size_h" "$vendor" "$model" >&2
    i=$((i + 1))
  done
  echo "" >&2
  local n="${#metas[@]}"
  local answer
  stty echo icanon 2>/dev/null || true
  tui_show_cursor
  read -r -p "Type 'yes' to FORMAT all $n selected drives after tests pass: " answer
  if [[ "$answer" == "yes" ]]; then
    FLASH_TEST_FORMAT_CONFIRMED=1
    echo "Format confirmed." >&2
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

# ---------------------------------------------------------------------------
# Live progress table + log pane
# ---------------------------------------------------------------------------
tui_live_view() {
  local report_dir="$1"
  local focus=0
  local key

  if [[ ! -t 1 ]]; then
    while [[ "${FLASH_TEST_LIVE_DONE:-0}" != "1" ]]; do
      sleep 0.5
    done
    return 0
  fi

  tui_alt_on
  tui_hide_cursor
  stty -echo -icanon time 1 min 0 2>/dev/null || true
  trap 'tui_show_cursor; stty echo icanon 2>/dev/null || true; tui_alt_off' EXIT

  while true; do
    local -a status_files=()
    mapfile -t status_files < <(find "$report_dir" -maxdepth 1 -name '*.status' 2>/dev/null | sort)

    if ((focus >= ${#status_files[@]} && ${#status_files[@]} > 0)); then
      focus=$((${#status_files[@]} - 1))
    fi

    tui_clear
    printf 'DEV            SERIAL           STATUS     STEP        PROGRESS  SPEED              RESULT\n'
    printf '─────────────────────────────────────────────────────────────────────────────────────────────\n'

    local sf i=0
    local focused_log=""
    for sf in "${status_files[@]:-}"; do
      local dev serial st step prog speed result log
      dev="$(reporter_get "$sf" dev)"
      serial="$(reporter_get "$sf" serial)"
      st="$(reporter_get "$sf" status)"
      step="$(reporter_get "$sf" step)"
      prog="$(reporter_get "$sf" progress)"
      speed="$(reporter_get "$sf" speed)"
      result="$(reporter_get "$sf" result)"
      log="$(reporter_get "$sf" log)"
      local marker=" "
      if ((i == focus)); then
        marker=">"
        focused_log="$log"
      fi
      printf '%s%-13s %-16s %-10s %-11s %-9s %-18s %s\n' \
        "$marker" "$(basename "${dev:-?}")" "${serial:0:16}" "${st:0:10}" \
        "${step:0:11}" "${prog:0:9}" "${speed:0:18}" "$result"
      i=$((i + 1))
    done

    if ((${#status_files[@]} == 0)); then
      echo "(waiting for workers…)"
    fi

    printf '\n── log'
    if [[ -n "$focused_log" ]]; then
      printf ' (%s)' "$(basename "$focused_log")"
    fi
    printf '  [j/k focus · q detach] ──\n'
    if [[ -n "$focused_log" && -f "$focused_log" ]]; then
      tail -n 12 "$focused_log" 2>/dev/null || true
    else
      echo "(no log yet)"
    fi

    if [[ "${FLASH_TEST_LIVE_DONE:-0}" == "1" ]]; then
      echo ""
      echo "══ batch complete — press any key ══"
      stty -echo -icanon time 0 min 1 2>/dev/null || true
      IFS= read -r -n1 _ || true
      break
    fi

    key=""
    IFS= read -r -n1 -t 0.5 key || true
    if [[ "$key" == $'\033' ]]; then
      local r1 r2
      IFS= read -r -n1 -t 0.05 r1 || true
      IFS= read -r -n1 -t 0.05 r2 || true
      [[ "$r2" == "A" ]] && key="k"
      [[ "$r2" == "B" ]] && key="j"
    fi
    case "$key" in
      q|Q) break ;;
      j)
        ((${#status_files[@]} > 0)) && focus=$(( (focus + 1) % ${#status_files[@]} ))
        ;;
      k)
        ((${#status_files[@]} > 0)) && focus=$(( (focus - 1 + ${#status_files[@]} ) % ${#status_files[@]} ))
        ;;
    esac
  done

  tui_show_cursor
  stty echo icanon 2>/dev/null || true
  tui_alt_off
  trap - EXIT

  echo ""
  echo "Final results:"
  mapfile -t status_files < <(find "$report_dir" -maxdepth 1 -name '*.status' 2>/dev/null | sort)
  local passed=0 failed=0
  for sf in "${status_files[@]:-}"; do
    local result serial dev
    result="$(reporter_get "$sf" result)"
    serial="$(reporter_get "$sf" serial)"
    dev="$(reporter_get "$sf" dev)"
    printf '  %s  %s  %s\n' "$(basename "$dev")" "$serial" "$result"
    if [[ "$result" == "PASSED" ]]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done
  echo "Passed: $passed  Failed: $failed"
  echo "Reports: $report_dir"
}
