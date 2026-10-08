# elpis-linux
 ΕΛΠΙΣ Resolver Linux

A small Linux whose only job is to run the
[Elpis recursive resolver](https://github.com/PururinCollective/elpis-resolver).
One ISO does everything: start it from a CD to try it, or write it to a USB
stick, SSD or hard disk and it keeps its settings and updates on that disk.

Built with [Buildroot](https://buildroot.org) 2026.02 LTS: Linux 6.18, musl,
BusyBox, GRUB 2.12. The whole system runs from RAM.

## How it works

```
USB stick / SSD / HDD, after the first start
┌──────────────────────────────┬────────┬───────────────────────────────────────┐
│ p1  ISO 9660 — never written │ p2 ESP │ p3  ELPIS-DATA  ext4, rest of the disk│
│ GRUB, kernel, rootfs         │ (EFI)  │ config/   saved settings              │
│ = factory and recovery image │        │ system/   installed updates           │
│                              │        │ grubenv   which update GRUB starts    │
└──────────────────────────────┴────────┴───────────────────────────────────────┘
```

At every start, before the network comes up, `elpis-storage` finds the ISO it
was started from and decides where settings live:

| Started from | Settings are kept on | Updates |
|---|---|---|
| The ISO written to a USB stick, SSD or HDD | p3 on that disk, added at the first start | installed to p3 |
| A CD, or a virtual CD, plus a disk that holds `ELPIS-DATA` | that disk | installed there, or attach a newer ISO |
| A CD plus a blank disk | that disk, once you run `elpis-storage format-blank` | as above |
| A CD alone, Ventoy, or a disk laid out some other way | RAM only: lost at reboot | — |

It only ever adds a partition to a disk that holds this exact ISO (matched by
its build-unique volume UUID) and nothing else: p1 the ISO, p2 its EFI
partition. A disk with any other partition is left alone. It formats another
disk only when asked to.

`ELPIS-DATA` starts 1 GiB into the disk when there is room, so a later, larger
ISO can be written over the front without reaching it.

## Building

On a Debian or Ubuntu host:

```bash
sudo apt install build-essential git wget curl rsync bc cpio unzip file perl python3
```

```bash
make
```

The first build downloads Buildroot, a prebuilt musl toolchain and the sources,
and takes 30–60 minutes. The result is
`output/images/elpis-<version>-x86_64.iso`, with a `.sha256` beside it.

| | |
|---|---|
| `make RESOLVER_SRC=../elpis-resolver` | build the resolver from a local checkout instead of the release tag (then `make elpis-resolver-dirclean` once when switching back and forth) |
| `make ELPIS_LINUX_VERSION=0.1.1` | another version than `VERSION` |
| `make menuconfig`, `make linux-menuconfig`, `make savedefconfig` | passed to Buildroot |
| `make legal-info` | every package's licence and source, for redistribution |
| `make clean` | remove `output/`; downloads in `dl/` stay |

The resolver's build string, which its identity probe and status page report,
is the release tag for a release build. For a `RESOLVER_SRC` build it is
whatever that checkout's own `make` would have said.

## Writing it to a disk

Any ISO writer works: balenaEtcher, Rufus in DD mode, or

```bash
sudo dd if=output/images/elpis-0.1.0-x86_64.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

It starts on BIOS and UEFI machines, from a CD or from a disk. On Proxmox,
attach the ISO as a CD and add a small disk (1 GiB is plenty), then run
`elpis-storage format-blank` once. Or import the ISO as the VM's disk.

From a running Elpis, `elpis-copy-to-disk --disk sdb --keep-config` writes the
system onto another disk and carries the settings over.

## The boot menu

| Entry | |
|---|---|
| **Elpis *version*** | the default: the installed update if there is a good one, else the ISO's own version |
| **Elpis *version* (built in to this medium)** | ignore installed updates this time |
| **Safe mode** | start without putting saved settings back (they stay on `ELPIS-DATA`) |
| **Factory reset … → Erase all settings and updates** | reformat `ELPIS-DATA`, then start the ISO's own version |

## Settings

Everything runs from RAM. A change lasts until the next reboot unless it is
saved:

```bash
vi /etc/elpis/elpis.conf
/etc/init.d/S50elpis restart     # the resolver's cache starts empty
elpis-save                       # keep it
```

`elpis-save` copies the files in `/etc/elpis/keep.list` to `ELPIS-DATA`:
`elpis.conf`, the network settings, the hostname, the root password, the NTP
servers. `elpis-save /some/path` adds a path to the list. Anything else you
change is gone at the next start, by design: the system stays exactly what
the ISO shipped.

After an update, a saved `elpis.conf` is merged with the new version's
defaults by the resolver's own `tools/conf-merge.sh`, the way `make` does it in
a resolver checkout.

The appliance's `elpis.conf` is the resolver's reference config with four
changes: it answers on port 53 on every address, logs to syslog (`logread -f`),
and runs as the `elpis` account once the port is bound. Who may query is the
resolver's default: private and local addresses only.

The resolver is started by init, which restarts it if it ever exits. If the
config does not pass `elpis -t`, it runs with the image's defaults instead and
says so in the log.

### The clock

DNSSEC signatures are only valid between two dates, so the clock is set before
the resolver starts. NTP servers are given by address in
`/etc/elpis/ntp.conf`, since nothing can be looked up by name until the
resolver runs. Until NTP answers, the clock is never allowed behind the
image's build time or the last time saved on `ELPIS-DATA`.

## Updates

```bash
elpis-update --from-iso https://example.org/elpis-0.1.1-x86_64.iso
reboot
```

The update's kernel and root filesystem are copied to `ELPIS-DATA`. GRUB
starts the update up to three times; once the resolver answers on 127.0.0.1,
the update is kept. If it has not answered after three starts, GRUB goes back
to the version that worked. GRUB on the ISO is never rewritten, so an update
cannot break the bootloader. `elpis-update --revert` goes back to the ISO's own
version.

Updates installed over one ISO are ignored when the machine is started from a
different one. On a VM, attaching a newer ISO wins.

### Signing

An image built with an update key accepts only updates signed by it.

```bash
mkdir -p keys
output/host/bin/minisign -G -W -p keys/update.pub -s keys/update.key
make SIGNING_KEY=keys/update.key
```

`keys/update.pub` is built into the image automatically when it exists. The
secret key signs the ISO and writes `elpis-<version>-x86_64.iso.minisig`. It
must be a key without a password (`-W`). Keep it out of the repository:
`.gitignore` already excludes `*.key`. An image without a key refuses every
update unless you pass `--allow-unsigned`. BusyBox's `wget` does not check
TLS certificates, so the signature is what makes an update trustworthy.

## Testing

```bash
tests/elpis-test.py                       # all scenarios against the newest ISO
tests/elpis-test.py cd disk               # some of them
tests/elpis-test.py --iso A.iso --update-iso B.iso --key keys/test.key update
```

These boot the ISO in QEMU with KVM: as a CD, written to a disk under BIOS and
UEFI (OVMF), a CD plus a blank disk, a disk with foreign partitions, a copy
made with `elpis-copy-to-disk`, and a signed update followed by a broken one
that GRUB has to fall back from. Every serial console is logged in
`tests/work/`.

## For the elpis-config TUI

What the boot scripts provide, for a front end to build on:

| | |
|---|---|
| `/run/elpis/state` | shell-sourceable: `MODE` (`persistent` or `ram`), `REASON` (why RAM only), `MEDIA_UUID`, `MEDIA_DISK`, `MEDIA_WRITABLE`, `DATA_DEV`, `DATA_UUID`, `SLOT` (`builtin` or an update), `SAFE`, `RESET`, `CREATED`, `GRUBENV_WRITABLE` |
| `/data` | `ELPIS-DATA`, mounted only when `MODE=persistent` |
| `elpis-save [PATH...]` | exit 0 saved, 1 failed, 3 RAM only |
| `elpis-storage status`, `format-blank DISK --yes`, `request-reset` | |
| `elpis-update --status`, `--from-iso FILE\|URL [--sig ...]`, `--revert`, `--prune` | |
| `elpis-copy-to-disk --list`, `--disk DISK [--keep-config] --yes` | |
| `/etc/init.d/S50elpis restart` | restart the resolver |
| `/run/elpis/health` | `up` once the resolver answered after boot, `down` if it did not |

Files a TUI would own, all in the keep list: `/etc/elpis/elpis.conf`,
`/etc/network/interfaces`, `/etc/hostname`, `/etc/elpis/ntp.conf`, `/etc/shadow`
(root password), `/etc/dropbear`.

## Layout

| | |
|---|---|
| `configs/elpis_x86_64_defconfig` | the Buildroot configuration |
| `package/elpis-resolver/` | builds the resolver from its release tag |
| `board/elpis/linux.fragment`, `busybox.fragment` | kernel and BusyBox changes on top of their defaults |
| `board/elpis/post-build.sh` | release identity, the appliance's `elpis.conf` |
| `board/elpis/post-image.sh` | GRUB core images and the hybrid ISO |
| `board/elpis/grub/` | the boot menu, with the update and fallback logic |
| `board/elpis/rootfs-overlay/` | `elpis-storage`, `elpis-save`, `elpis-update`, `elpis-copy-to-disk`, init scripts |
| `tests/elpis-test.py` | the QEMU tests |

## Not yet

- No SSH: the console (screen or serial) is the only way in. The root account
  has no password until you set one with `passwd` and keep it with `elpis-save`.
- No guided setup yet: network and resolver settings are edited by hand.
  An `elpis-config` TUI is planned.
- x86-64 only.

## Licence

The resolver is GPL-2.0; its licence is in the image at
`/usr/share/licenses/elpis-resolver/LICENSE` and on the ISO under `licenses/`.
`make legal-info` collects the licences and sources of every package in the
image.
