# paddock

An open-source macOS sandbox fleet for AI agents, CI and remote development on Apple silicon.

This repository is at MVP step 1: a host agent spike that drives Virtualization.framework
directly to install macOS, boot it, make copy-on-write clones and time how fast a clone becomes
usable. It has no Tart or Lume dependency.

## Requirements

- An Apple silicon Mac running macOS 14 or later.
- Swift 6 from Xcode or the Command Line Tools.
- Disk space for one restore image (about 26 GB for macOS 27) plus the golden VM's disk. The disk
  is sparse, so a fresh install takes about 25 GB of its nominal 80 GB. Delete the cached image
  in `~/.paddock/cache/ipsw` once installed if space is tight; `install` downloads it again.

## Build

```bash
scripts/build.sh
```

The script builds a release binary, signs it ad hoc with the
`com.apple.security.virtualization` entitlement from `paddock.entitlements`, checks the
signature and prints the binary's path. Virtualization.framework refuses to start VMs from an
unsigned binary. Pass `debug` for a debug build. Run the tests with `swift test`.

The script also puts `paddock-guestd`, the agent that runs inside each guest, in a `guest`
folder next to the binary, with its launchd job and `install.sh`. The agent listens only on
vsock port 52525 and answers one line of JSON per connection; today the only request is
`{"op":"health"}`, which returns its version.

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
| `paddock bench <source> [--runs 1] [--timeout 300] [--ssh-timeout 60] [--restore] [--keep]` | Clones the source, boots the clone headless, prints timings, then stops and deletes the clone. With `--restore`, each run restores a saved state instead of cold booting. |
| `paddock serve <source>` | Keeps one warm clone of the source running headless. At startup it boots a clone with the slot's own identity until SSH answers and saves its state; each warm VM is a fresh clone restored from that state. If the warm VM stops, serve restores another. Ctrl-C stops it and deletes the slot's VMs. |
| `paddock acquire` | Takes the warm VM from `serve` and prints its name and address, waiting while the slot fills. |
| `paddock release <vm>` | Hands a VM back to `serve`, which force-stops it, deletes the clone and restores a fresh one. |

`acquire` and `release` reach `serve` through `~/.paddock/serve.sock`, a Unix socket only its
owner can open. Each connection carries one line of JSON each way. Only one `serve` can listen
at a time.

VMs live in `~/.paddock/vms` and restore images in `~/.paddock/cache/ipsw`. Set
`PADDOCK_HOME` to use another directory. A VM that is running is locked, so it can't be cloned
mid-write.

## What bench measures

| Step | What it covers |
| --- | --- |
| clone | Locking the source, `clonefile(2)` of the disk and auxiliary storage, writing the new identity and renaming the clone into place. |
| start | Building and validating the VM configuration, creating the VM and starting it, until Virtualization.framework reports it running. |
| running | From the same moment as start until the guest holds a DHCP lease in `/var/db/dhcpd_leases`, checked every 100 ms. |
| ssh | From the same moment as start until the guest's SSH server sends its banner, checked every 250 ms. |

Each run also prints clone to running, the total from cloning to a guest on the network. The
lease and SSH checks see the guest from the outside without installing anything in it. The next
spike replaces them with a guest agent answering over vsock, which the VM already has a device
for.

With `--restore`, bench first cold-boots one clone until SSH answers, pauses it and saves its
memory and device state (printed as save, with the file size, and left out of the summary).
Each run then clones that saved VM and replaces start and running with:

| Step | What it covers |
| --- | --- |
| clone | As above, plus `clonefile(2)` of the saved state. The clone keeps the saved VM's machine identifier and MAC address, because the saved memory still holds them. |
| restore | Building and validating the VM configuration, creating the VM and loading the saved state, until the VM is paused. |
| resume | From the same moment as restore until Virtualization.framework reports the VM running. |
| ssh | From the same moment as restore until the guest's SSH server sends its banner. The guest keeps the address it leased before it was saved. |

Restored clones share one identity, so only one can run at a time.

## VM bundle format

```
~/.paddock/vms/<name>/
  disk.img     sparse raw disk image
  aux.img      Mac auxiliary storage
  config.json  hardware model and machine identifier (base64), MAC address,
               CPU count, memory, disk size, display and the installed macOS build
  state.vzvmsave  optional saved memory and device state of a paused VM
```

## Limits

- macOS allows at most two macOS VMs running at once on one host.
- Clones must be on the same APFS volume as their source. Cloning fails rather than copying.
- Networking is NAT only.
- Every clone has a new MAC address, so every boot takes a new lease from macOS's DHCP server,
  which keeps leases for a day. The NAT network has about 250 addresses, so a few hundred clone
  boots in one day exhaust it and new guests get no address. Shorten the lease time if you
  benchmark heavily:

  ```bash
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600
  ```
- `serve` has one slot with one identity, so every VM it hands out has the same MAC address, IP
  address and SSH host key. Each starts with its clock behind by the time since `serve` saved
  the slot's state.
- Apple's macOS license permits macOS VMs for development and testing.

## License

Apache 2.0. See [LICENSE](LICENSE).
