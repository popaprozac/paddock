# paddock

An open-source macOS sandbox fleet for AI agents, CI and remote development on Apple silicon.

This repository is at MVP step 1: a host agent spike that drives Virtualization.framework
directly to install macOS, boot it, make copy-on-write clones and time how fast a clone becomes
usable. It has no Tart or Lume dependency.

## Requirements

- An Apple silicon Mac running macOS 14 or later.
- Swift 6 from Xcode or the Command Line Tools.
- Disk space for one restore image (about 26 GB for macOS 27) plus the golden VM's disk. The disk
  is sparse, so a fresh install takes about 30 GB of its nominal 80 GB.

## Build

```bash
scripts/build.sh
```

The script builds a release binary, signs it ad hoc with the
`com.apple.security.virtualization` entitlement from `paddock.entitlements`, checks the
signature and prints the binary's path. Virtualization.framework refuses to start VMs from an
unsigned binary. Pass `debug` for a debug build. Run the tests with `swift test`.

## Make a golden image and benchmark it

```bash
paddock install golden        # download the latest supported macOS and install it
paddock run golden            # finish Setup Assistant in the window
paddock bench golden --runs 3 # clone, boot headless, time each step, delete the clone
```

While Setup Assistant is open in `paddock run`, set up the guest the way every clone should be:

1. Create the user account.
2. Turn on Remote Login in System Settings, under General and then Sharing. `bench` uses it to
   time when SSH answers.
3. Optionally turn on automatic login and stop the guest from sleeping, so clones come up ready.
4. Shut down from the Apple menu. Closing the window or pressing Ctrl-C also asks the guest to
   shut down; doing it a second time forces the VM off.

## Commands

| Command | What it does |
| --- | --- |
| `paddock install <name> [--ipsw path] [--cpus 4] [--memory 8] [--disk-size 80]` | Finds the latest macOS this Mac supports, downloads it into the cache and installs it into a new VM. Memory and disk are in GB. |
| `paddock run <name>` | Boots a VM in a window. |
| `paddock clone <source> <name>` | Makes an APFS copy-on-write clone with a fresh machine identifier and MAC address. |
| `paddock bench <source> [--runs 1] [--timeout 300] [--ssh-timeout 60] [--keep]` | Clones the source, boots the clone headless, prints timings, then stops and deletes the clone. |

VMs live in `~/.paddock/vms` and restore images in `~/.paddock/cache/ipsw`. Set
`PADDOCK_HOME` to use another directory. A VM that is running is locked, so it can't be cloned
mid-write.

## What bench measures

| Step | From | Until |
| --- | --- | --- |
| clone | `clonefile(2)` starts | the clone has a new machine identifier and MAC address |
| start | the VM configuration is built | Virtualization.framework reports the VM running |
| running | the VM is asked to start | the guest holds a DHCP lease, read from `/var/db/dhcpd_leases` |
| ssh | the VM is asked to start | the guest's SSH server sends its banner |

Each run also prints clone to running, the total from cloning to a guest on the network. The
lease and SSH checks see the guest from the outside without installing anything in it. The next
spike replaces them with a guest agent answering over vsock, which the VM already has a device
for.

## VM bundle format

```
~/.paddock/vms/<name>/
  disk.img     sparse raw disk image
  aux.img      Mac auxiliary storage
  config.json  hardware model and machine identifier (base64), MAC address,
               CPU count, memory, disk size, display and the installed macOS build
```

## Limits

- macOS allows at most two macOS VMs running at once on one host.
- Clones must be on the same APFS volume as their source. Cloning fails rather than copying.
- Networking is NAT only.
- Apple's macOS license permits macOS VMs for development and testing.

## License

Apache 2.0. See [LICENSE](LICENSE).
