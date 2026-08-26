# flash-test — Simple one-drive flash tester

Bash TUI that tests **one** USB flash drive: SMART (`smartctl`), fake capacity (`f3probe`), surface (`badblocks`), speed (`hdparm`), then optional exFAT reformat + `fsck`.

## Warning

**Destructive** after the SMART gate. Only removable (`RM=1`) disks that are not the system disk are accepted. You must type `yes` before destructive tests start, and again before formatting.

## SMART self-test

If the stick supports SMART self-tests, flash-test can start a **long offline** test and exit. Leave the drive plugged in, then run again later: it shows the self-test log and continues to the destructive pipeline.

Pending state lives at `logs/<uuid>/smart-selftest.state`.

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
./flash-test --list    # list safe removable targets
./flash-test --help
```

## License

See [LICENSE](LICENSE) if present; otherwise use at your own risk.
