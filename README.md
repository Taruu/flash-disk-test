# flash-test — Simple one-drive flash tester

Bash TUI that tests **one** USB flash drive: fake capacity (`f3probe`), surface (`badblocks`), SMART (`smartctl`), speed (`hdparm`), then optional exFAT reformat + `fsck`.

## Warning

**Destructive.** Only removable (`RM=1`) disks that are not the system disk are accepted. You must type `yes` before tests start, and again before formatting.

## Dependencies

```bash
sudo apt install f3 e2fsprogs smartmontools hdparm parted exfatprogs util-linux
```

## Quick start

```bash
sudo ./flash-test
```

- `j` / `k` — move
- `Enter` — select drive
- `r` — refresh list
- `q` — quit

Live output is shown in the TUI and saved to:

```text
logs/<uuid>/<YYYYMMDDTHHMMSS>.log
```

## Also

```bash
./flash-test --list    # list safe removable targets (no root needed for list alone if readable)
./flash-test --help
```

## License

See [LICENSE](LICENSE) if present; otherwise use at your own risk.
