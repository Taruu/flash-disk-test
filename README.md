# flash-test — Single Flash Drive QA

Bash CLI that tests **one** USB flash drive per process: fake-capacity (`f3`), surface scan (`badblocks`), speed (`fio`), then optional format.

Run several terminals (or `--state-file` instances) yourself to test multiple sticks at once.

## Warning

**Destructive by default.** Only removable (`RM=1`) disks that are not the system disk are accepted. Formatting requires typing `yes` in the TUI, or `--yes-format` on the CLI.

## Dependencies

```bash
sudo apt install f3 e2fsprogs fio parted exfatprogs util-linux udev python3
```

## Quick start

```bash
# Terminal 1 — pick a drive (UUID is shown and saved)
sudo ./flash-test

# Terminal 2 — another stick, separate saved selection
sudo ./flash-test --state-file ./state/stick2.conf

# Reuse last saved UUID for this state file
sudo ./flash-test --use-saved

# Show / clear saved selection
./flash-test --show-selection
./flash-test --clear-selection

# Non-interactive
sudo ./flash-test /dev/sdb --format none
sudo ./flash-test --list
```

### TUI

- `j` / `k` — move
- `enter` or `c` — select **one** drive (saved immediately)
- `r` — refresh list
- `q` — quit

The picker shows each drive’s **UUID** (partition-table UUID when available, otherwise serial). A `*` marks the previously saved stick. After confirm, the live view shows UUID, step, progress, and a log tail.

## Parallel sticks

One process = one drive. Example:

```bash
sudo ./flash-test --state-file ./state/a.conf   # pick stick A
sudo ./flash-test --state-file ./state/b.conf   # pick stick B in another terminal
```

## Layout

```
flash-test
lib/safety.sh detector.sh selection.sh tui.sh runner.sh reporter.sh
lib/tests/          f3 / badblocks / fio / format
state/              saved UUID per instance (gitignored)
reports/<uuid>/…    per-run logs + summary.json
tests/mock_loop.sh
```

## License

See [LICENSE](LICENSE).
