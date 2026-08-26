# flash-test — Multi-Drive Flash QA Engine

Bash CLI to **batch-test multiple USB flash drives concurrently**: fake-capacity (`f3`), surface scan (`badblocks`), speed (`fio`), then optional format.

## Warning

**Destructive by default.** Tests overwrite drive contents. Only removable (`RM=1`) disks that are not the system/root disk are accepted. Formatting requires an explicit TUI `yes` or CLI `--yes-format`.

## Dependencies

| Package / tool | Purpose |
| --- | --- |
| `util-linux` | `lsblk`, `findmnt`, `wipefs`, `losetup` |
| `udev` | `udevadm` |
| `f3` | `f3probe`, `f3write`, `f3read` |
| `e2fsprogs` | `badblocks` |
| `fio` | throughput / IOPS |
| `parted` | partition table |
| `exfatprogs` or `exfat-utils` | `mkfs.exfat` (default format) |
| `dosfstools` | `mkfs.vfat` (optional) |
| `python3` | parse `fio` JSON / write summaries |
| Bash ≥ 4.3 | `wait -n` job control |

Debian/Ubuntu example:

```bash
sudo apt install f3 e2fsprogs fio parted exfatprogs util-linux udev python3
```

## Quick start

```bash
sudo ./flash-test                  # TUI: select drives, confirm format, live progress + logs
sudo ./flash-test --list           # show safe targets only
sudo ./flash-test --quick /dev/sdb --format none
sudo ./flash-test --all --mode full --jobs 4 --format exfat --yes-format --output ./reports/run1
sudo ./flash-test --non-destructive /dev/sde --format none
```

### TUI controls

**Drive picker**

- `j` / `k` or arrows — move
- `space` — toggle selection
- `a` — select / clear all
- `r` — refresh device list
- `enter` or `c` — confirm
- `q` — quit

**Format gate** — if `--format` is not `none`, type `yes` to format all selected drives after tests pass. Otherwise continue without format or abort.

**Live run view** — progress table + log pane; `j`/`k` switch focused drive log; `q` detaches from the live view (batch continues).

## Safety model

1. Require root.
2. Accept only `TYPE=disk` with `RM=1` (or `--allow-loop`).
3. Refuse root-backing disk and system mounts (`/`, `/boot`, `/home`, `/var`, `/usr`, swap).
4. Pin each target to `/dev/disk/by-id/...` before I/O.
5. Re-check mounts after `umount` before write stages.
6. Format only after confirmation **and** a full test pass.

## Layout

```
flash-test                 entrypoint
lib/safety.sh              root, deps, exclusions, by-id pin
lib/detector.sh            enumeration + metadata
lib/tui.sh                 picker, format confirm, live view
lib/runner.sh              job pool, write semaphore, signals
lib/reporter.sh            status files, CSV/JSON
lib/tests/                 f3, badblocks, fio, format stages
tests/mock_loop.sh         losetup mock harness
reports/                   default output (gitignored)
```

## Mock / CI testing (loop devices)

```bash
sudo ./tests/mock_loop.sh setup 2 64
sudo ./flash-test --allow-loop --format none --jobs 2 --mode quick /dev/loopX /dev/loopY
sudo ./tests/mock_loop.sh teardown

# or one-shot smoke (creates loops, runs, tears down):
sudo ./tests/mock_loop.sh run-smoke
```

Fault injection:

```bash
sudo ./tests/mock_loop.sh fault-ro /dev/loop0   # expect skip/fail on RO
```

## Reports

Each run writes under `--output` (default `reports/<timestamp>/`):

- per-drive `.log`, `.status`, `.json`
- `summary.csv` / `summary.json`
- `format_outcome` may be `skipped_no_confirm` when format was declined or `--yes-format` was omitted

## License

See [LICENSE](LICENSE).
