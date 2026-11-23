# Commands

| Command | What it does |
| --- | --- |
| `paddock install <name> [--ipsw path] [--cpus 4] [--memory 8] [--disk-size 80]` | Finds the latest macOS this Mac supports, downloads it into the cache and installs it into a new VM. Memory and disk are in GB. |
| `paddock run <name> [--share folder] [--provision account [--full-name name]] [--recovery]` | Boots a VM in a window. `--share` mounts a host folder read-only in the guest; `--provision` creates the account on the first boot after `install`, on a macOS 27 or later guest (older guests ignore it); `--recovery` starts it in macOS Recovery. A Linux VM with a desktop opens in the window too, at its image's screen size, which the window scales rather than changes, and so does a Windows VM. A Linux VM without a desktop has no screen, so `run` connects this terminal to its console instead, logged in as its account; Ctrl-] asks the guest to shut down and a second Ctrl-] forces it off, and `--share` is then mounted by hand in the guest (see [Linux images](golden-images.md#linux-images)). `--share` attaches the folder to a Windows VM too, but Windows needs virtio-win's virtiofs service and WinFsp to mount it, which is untested. |
| `paddock init <file> [--template minimal\|ci\|managed\|debian\|debian-desktop\|ubuntu\|ubuntu-desktop]` | Writes a commented starter image file for `build`; `debian` and `ubuntu` are Linux images, and `debian-desktop` and `ubuntu-desktop` ones with Xfce and GNOME (see [Desktop Linux](golden-images.md#desktop-linux)). |
| `paddock build <file> [--guest folder]` | Makes a golden image from an image file, with no one at the keyboard: installs macOS, creates the account, installs the guest agent, turns off what would stop unattended VMs, optionally accepts the license and writes the grants, runs the file's steps and checks the image (see [Make a golden image](golden-images.md)). Needs macOS 27 on this Mac and macOS 15 or later in the VM. A Linux image file (`from: debian`, `ubuntu`, `disk` or `url`) needs neither, nor a password: `build` makes the VM from the image's disk, boots it once with a cloud-init seed that creates the account and installs the guest agent, then runs the steps and seals the image (see [Linux images](golden-images.md#linux-images)). `build` doesn't make Windows images yet (see [Windows images](golden-images.md#windows-images)). |
| `paddock grant <name>` | Grants `paddock-session` Accessibility and `paddock-guestd` Full Disk Access in a shut-down golden image from macOS Recovery, with SIP on (see [What a golden image allows](golden-images.md#what-a-golden-image-allows)). |
| `paddock clone <source> <name>` | Makes an APFS copy-on-write clone with a fresh machine identifier and MAC address. |
| `paddock bench <source> [--runs 1] [--timeout 300] [--restore] [--userspace] [--keep]` | Clones the source, boots the clone headless, prints timings, then stops and deletes the clone. With `--restore`, each run restores a saved state instead of cold booting. With `--userspace`, each VM gets its own userspace network instead of the shared NAT, and there is no running step. |
| `paddock serve <source> [--slots 2] [--userspace] [--control url [--join token]]` | Keeps a warm clone of the source running headless in each of its slots: two by default, as many VMs as macOS runs at once, or one with `--slots 1` on a Mac that also runs another VM; a Linux or Windows image can have any number, as memory allows. At startup it boots a clone in each slot, at the same time, with the slot's own identity until it is ready and saves its state; each warm VM is a fresh clone restored from its slot's state, handed out once it is ready again. A VM is ready once its guest agent answers and the guest reports an IPv4 address and an IPv4 DNS server, and, if the source has `paddock-session` installed, once the helper answers and says loginwindow has finished the login, which means the desktop takes input. A helper before 0.2.0 can't say, so `serve` then waits only for it to answer. If a warm VM stops, its slot restores another. When a slot's state won't restore, as while the Mac's screen is locked, the slot boots a fresh clone of the source instead, and tries its state again at the next refill (see [What serve needs](hosts.md#what-serve-needs)). For a Linux or Windows image, `serve` sets each warm VM's clock from the Mac's, since a restored guest resumes at the time its state was saved. A slot that can't start or refill, for example because another VM is already running, is empty with the reason while the others serve on, and tries again after 5 s, then after twice the last wait each time, up to 5 minutes. If no slot can start when `serve` starts, it exits. serve warns when its VMs together would leave the Mac little memory, counting each macOS VM at about 1.7 times its own memory and each Linux VM at 1.15 times, or 1.6 times with a desktop, and each Windows VM at 1.6 times; it warns again if macOS's memory pressure rises to warn or critical while it runs. Ctrl-C, or SIGTERM as launchd sends, stops it and deletes the slots' VMs (see [Running serve at login](hosts.md#running-serve-at-login)); a serve stopped without that chance, as by Force Quit, leaves them, and the next serve for the same source deletes those it finds, by their slot names, unless something holds them. While it runs, it keeps the Mac from idle sleep. It samples what this Mac and its VMs use every 2 s, for `paddock top`. With `--control`, it also links this Mac to a control plane and reports its slots and that usage there; `--join` the first time (see [A pool of Macs](control-plane.md)). |
| `paddock acquire [--allow names] [--image name]` | Takes a warm VM from `serve` and prints its name and address, waiting while the slots fill. On a Mac logged in to a control plane it takes one from the pool, and `--image` names the golden image when the pool serves more than one. With `serve --userspace`, the VM reaches only the names in `--allow`, comma-separated, and nothing without it (see [The userspace network](network.md)); `--allow` against a `serve` on NAT fails. |
| `paddock exec <vm> -- <command>` | Runs a command in a VM that `acquire` handed out, through its guest agent over vsock, streams the output and exits with the command's status. The words after `--` are joined with spaces, as `ssh` does. |
| `paddock task <vm> --bundle <in> --result <out> -- <command>` | Copies a git bundle of a branch (made with `git bundle create <in> HEAD`) into the VM over vsock, clones it, runs the command in the clone and commits whatever it changed, authored as paddock, even if the command fails. If git can't commit what the command left, as with a stale `index.lock`, the commits the command made still come back, and `task` says the rest stays in the VM's clone. New commits come back as a bundle at `<out>`, ready for `git fetch <out> HEAD:<branch>`; with none, it prints `No changes`. Exits with the command's status. The guest needs `git`: the Command Line Tools in a macOS image, a build step that installs it in a Linux one (see [Linux images](golden-images.md#linux-images)), or Git for Windows, such as MinGit, on the machine's `PATH` in a Windows one (see [Windows images](golden-images.md#windows-images)); without it, `task` stops, saying so. In a Windows guest the steps run in `cmd.exe`, and the clone keeps files' line endings as committed, whatever Git's `core.autocrlf` says. |
| `paddock screenshot <vm> [-o file.png]` | Saves the screen of a VM that `acquire` handed out as a PNG, `<vm>.png` in the current folder by default. `serve` reads the VM's framebuffer on this Mac, so the guest grants nothing and runs nothing (see [Screenshots](agents.md#screenshots)). |
| `paddock axtree <vm>` | Prints the accessibility tree of the focused app in a VM that `acquire` handed out, as JSON, from `paddock-session` in a macOS guest, or from the guest agent, which reads AT-SPI in a desktop Linux guest and UI Automation in a Windows guest (see [Linux guests](guest-agent.md#linux-guests) and [Windows guests](guest-agent.md#windows-guests)). Its frames are in the same coordinates as `paddock screenshot`'s pixels. |
| `paddock click <vm> <x> <y> [--right] [--double]` | Clicks at a point of the guest's screen, in pixels from the top left, as in `paddock screenshot` (see [Input](agents.md#input)). |
| `paddock type <vm> <text>` | Types text into whatever has the keyboard focus in the guest, as key presses. |
| `paddock key <vm> <combination>...` | Presses key combinations in turn, such as `cmd+s`, `cmd+shift+z` or `return`. |
| `paddock scroll <vm> <x> <y> [--down n] [--up n] [--right n] [--left n]` | Scrolls by about n lines at a point of the guest's screen. |
| `paddock release <vm>` | Hands a VM back to `serve`, which force-stops it, deletes the clone and restores a fresh one. |
| `paddock show <vm>` | On the Mac whose `serve` runs it, puts a VM that `acquire` handed out on screen for a person, in a window that takes the mouse and keyboard, with the guest's resolution kept (see [Taking a VM over by hand](agents.md#taking-a-vm-over-by-hand)). |
| `paddock hide <vm>` | Hands a VM that `show` put on screen back to agents: its window goes off screen again. |
| `paddock view <vm> [--local] [--watch [--buffer <ms>]] [--stats]` | Opens a window onto a VM you acquired, from this Mac or any Mac logged in to the same control plane, and drives it with your mouse and keyboard; the screen comes as video through the control plane, and nothing connects to the VM's Mac. Input from agents and the CLI waits until the window closes, which hands the VM back. `--watch` only shows the screen, so agents keep driving: it takes no input and plays `--buffer` ms (400 by default) behind at an even pace, so a slow link doesn't freeze and catch up; two people can watch a VM at once. `--stats` prints frames a second, bitrate and freezes every 5 s (see [From another Mac: paddock view](agents.md#from-another-mac-paddock-view)). |
| `paddock top [--local] [--json]` | Shows this Mac's `serve`, or on a Mac logged in to a control plane the whole pool: each Mac's CPU, memory, memory pressure, free disk and thermal state, and each slot's VM, who holds it, how long it has been in its state and what it uses. Redraws every 2 s until Ctrl-C; with `--json`, or when the output isn't a terminal, prints one snapshot (see [Watching with paddock top](#watching-with-paddock-top)). |
| `paddock mcp` | Serves `serve`'s VMs, or the pool's on a logged-in Mac, to an agent as an MCP server on stdin and stdout (see [Agents over MCP](agents.md#agents-over-mcp)). |

These commands reach `serve` through `~/.paddock/serve.sock`, a Unix socket only its owner can
open. Each connection carries one request line of JSON and gets one or more answer lines back;
`exec` streams one per line of output, then the exit status; a view also sends its own lines,
its acknowledgments and input, for as long as it lasts. Only one `serve` can listen at a
time. On a Mac logged in to a control plane, `acquire`, the commands that take a VM and
`paddock mcp` use its pool instead; `--local`, or `PADDOCK_LOCAL=1`, keeps them on this Mac. The
control plane's own commands, with `paddock login`, `logout` and `hosts`, are in
[A pool of Macs](control-plane.md#commands).

VMs live in `~/.paddock/vms` and restore images in `~/.paddock/cache/ipsw`. Set
`PADDOCK_HOME` to use another directory. A VM that is running is locked, so it can't be cloned
mid-write.

## Watching with paddock top

`serve` samples, every 2 s, what this Mac and each of its VMs use, and answers a `status`
request on its socket with it; with `--control`, it sends the same to the control plane. Every
number is measured on the Mac, so no guest is asked and none can change them:

| Column | What it is |
| --- | --- |
| CPU, for a Mac | Its whole CPU in use, as a share of all its cores. |
| MEMORY, for a Mac | Memory in use, as Activity Monitor's Memory Used counts it (app memory, wired and compressed), of the Mac's total, in binary GB. |
| PRESSURE | macOS's memory pressure: normal, warn or critical. |
| DISK FREE | Free space on the volume `serve` clones VMs to, in decimal GB or TB, as Finder counts it. |
| THERMAL | macOS's thermal state: nominal, fair, serious or critical. |
| HELD BY | Through a control plane: the client the VM was handed out to. A VM acquired with `--local` shows none. |
| FOR | How long the slot has been in its state. |
| CPU, for a VM | Its Virtualization.framework process's CPU, as a share of one core, as `top` counts it: 200% is two cores busy. |
| MEMORY, for a VM | That process's memory footprint: the guest's memory and the VM's own, so more than the VM's configured memory (see [Limits](limits.md)). |

`serve` finds each VM's process by the bundle's `disk.img` it holds open. CPU figures are the
change since the last sample, so a slot shows none for its first 2 s. On the pool, `top` keeps
one link to the control plane open while it runs.

## Run a task from another Mac

With a control plane, log in and run `paddock task` on any Mac: it runs on the pool, with no SSH
(see [A pool of Macs](control-plane.md)). Without one, `scripts/run-on-studio.sh`
runs a command in a fresh VM on another Mac, on the current repo's
last commit, and brings what it commits back as a local branch. It needs only `git` and `ssh` on
the Mac you run it from. The other Mac needs Remote Login on for your account, `paddock serve`
running, and the Command Line Tools in its golden image for `git` (see
[the ci template](golden-images.md#build-one-from-an-image-file)).

```bash
scripts/run-on-studio.sh you@studio.local -- 'swift test'
```

The script bundles `HEAD`, copies it over one SSH connection, runs `acquire`, `task` and
`release` on the other Mac, and fetches any new commits as `paddock/<date-time>`. It releases the
VM, which wipes it, and removes its temporary files even when the command fails, then exits with
the command's status. Uncommitted changes stay where they are. Set `PADDOCK_REMOTE` if paddock
isn't at `~/code/paddock/.build/out/Products/Release/paddock` on the other Mac.

## What bench measures

| Step | What it covers |
| --- | --- |
| clone | Locking the source, `clonefile(2)` of the disk and auxiliary storage, writing the new identity and renaming the clone into place. |
| start | Building and validating the VM configuration, creating the VM and starting it, until Virtualization.framework reports it running. |
| running | From the same moment as start until the guest holds a DHCP lease in `/var/db/dhcpd_leases`, checked every 100 ms. |
| agent | From the same moment as start until `paddock-guestd` answers a health check over vsock, checked every 100 ms. Runs alongside the lease check. |
| network | From the same moment as start until the guest reports, through its agent's `state` request, an IPv4 address on `en0` and an IPv4 DNS server, checked every 100 ms once the agent answers. An agent before 0.4.0 is asked through a command instead, which takes seconds while the guest's user is logging in. |
| session | From the same moment as start until `paddock-session` answers a health check over vsock, checked every 100 ms once the network is up. Only when the source has the helper installed; it starts when the user logs in, so it needs automatic login. |
| desktop | From the same moment as start until `paddock-session` says, through its `state` request, that loginwindow has finished the login, checked every 100 ms once the helper answers. A helper before 0.2.0 can't say, so the step ends as soon as it answers. |

Each run also prints clone to ready, the total from cloning to the last step: desktop when the
source has `paddock-session`, network otherwise. A run whose agent never answers or that never
reaches its last step fails. The lease check reads the host's
lease file and the agent and network checks go over vsock, so nothing in the guest listens on
the network for paddock. Each vsock connection gives up after 2 s if Virtualization.framework
hasn't called back, which now and then it never does, and the next check tries again.

With `--restore`, bench first cold-boots one clone until its last step, pauses it and saves its
memory and device state (printed as save, with the file size, and left out of the summary).
Each run then clones that saved VM and replaces start and running with:

| Step | What it covers |
| --- | --- |
| clone | As above, plus `clonefile(2)` of the saved state. The clone keeps the saved VM's machine identifier and MAC address, because the saved memory still holds them. |
| restore | Building and validating the VM configuration, creating the VM and loading the saved state, until the VM is paused. |
| resume | From the same moment as restore until Virtualization.framework reports the VM running. |
| agent | From the same moment as restore until `paddock-guestd` answers over vsock. The guest keeps the address it leased before it was saved, so there is no running step. |
| network | From the same moment as restore until the guest reports its IPv4 address and DNS server again. A restored guest renegotiates its network after it resumes, so this comes after the agent answers. Its IPv6 DNS server stays listed throughout, so only IPv4 counts. |
| session | From the same moment as restore until `paddock-session` answers, as above. |
| desktop | From the same moment as restore until `paddock-session` says loginwindow has finished the login, as above. |

Restored clones share one identity, so only one can run at a time.

## VM bundle format

```
~/.paddock/vms/<name>/
  disk.img     sparse raw disk image
  aux.img      Mac auxiliary storage (macOS)
  efi-vars     EFI variable store (Linux and Windows), in place of aux.img
  config.json  hardware model and machine identifier (base64), MAC address,
               CPU count, memory, disk size, display and the installed macOS build;
               "kind": "linux" for a Linux VM and "windows" for a Windows VM,
               "rosetta": true for a Linux VM with Rosetta,
               and "desktop": true for one with a desktop
  state.vzvmsave  optional saved memory and device state of a paused VM
  net.sock     paddock-net's control socket, while the VM runs on the userspace network
  console.log  a Linux guest's console, written afresh each time it starts
```

A Linux VM runs on Virtualization.framework's generic platform with EFI boot, a virtio disk,
network, entropy, vsock and console. Without a desktop it has no display, keyboard or pointer, so
screenshots, input, `show` and `view` refuse it; with one it has a virtio-gpu screen at its
display size and a USB keyboard and pointer (see [Desktop Linux](golden-images.md#desktop-linux)).
Its `config.json` has an empty hardware model and a generic machine identifier.

A Windows VM runs on the generic platform with EFI boot too, with a Linux desktop's devices: a
virtio-gpu screen at its display size, a USB keyboard and pointer, network, entropy and vsock,
and no console. Windows Boot Manager hangs at its first instructions unless two private
settings of Virtualization.framework's generic platform are on, performance monitoring unit
emulation and fine-grained traps, so paddock turns them on and refuses to start a Windows VM on
a macOS that lacks them. Its `config.json` is a Linux VM's, with `"kind": "windows"`.
