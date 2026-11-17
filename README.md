# paddock

An open-source macOS sandbox fleet for AI agents, CI and remote development on Apple silicon.

This repository is the MVP: a host agent that drives Virtualization.framework directly, with no
Tart or Lume dependency. On one Mac it can:

- install macOS and make APFS copy-on-write clones of a VM;
- keep a warm VM ready and hand it out in under a millisecond, then restore a saved state for
  the next one in about 6 s;
- run commands and git tasks in a guest through an agent that listens only on vsock;
- limit a guest's network to the names its session allows;
- read a guest's screen on the host, and its accessibility tree in the guest;
- click, type, press keys and scroll in a guest from the host;
- give an agent all of that as an MCP server, `paddock mcp`.

There is no control plane yet: each Mac runs its own `paddock serve`.

## Requirements

- An Apple silicon Mac running macOS 14 or later.
- Swift 6 from Xcode or the Command Line Tools.
- Go, for `paddock-net`. Its dependencies need Go 1.26; with an older Go installed, Go fetches
  1.26 itself on the first build.
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

The script also builds `paddock-net` next to the binary: each VM's userspace network stack,
when `bench` or `serve` runs with `--userspace` (see [The userspace network](#the-userspace-network)).
It is Go, on [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock), with its module
in `paddock-net/`. Run its checks with `go vet ./...` and `go test ./...` there.

The script also puts `paddock-guestd`, the agent that runs inside each guest, in a `guest`
folder next to the binary, with its launchd job and `install.sh`. The agent listens only on
vsock port 52525. Each connection carries one request line of JSON and gets one or more answer
lines back:

| Request | Answer |
| --- | --- |
| `{"op":"health"}` | `{"version":"0.5.0"}` |
| `{"op":"run","command":"..."}` | `{"output":"..."}` for each line of the command's combined stdout and stderr, then `{"exit":N}` |
| `{"op":"put","name":"...","size":N}` followed by N bytes | `{"exit":0}` once the file is stored |
| `{"op":"get","name":"..."}` | `{"chunk":n}` followed by n bytes, repeated, then `{"exit":0}` |
| `{"op":"state"}` | `{"output":"network"}` once en0 has an IPv4 address and the guest an IPv4 DNS server, `{"output":"session-helper"}` if `paddock-session` is installed, then `{"exit":0}` |

`run` uses a login shell (`zsh -l`) as the account with uid 501, the one created in Setup
Assistant, in its home folder, with stdin closed. Output lines over 8 KB are split. `put` and
`get` work on files in that account's `~/paddock` folder, named by one plain path component, up
to 4 GiB; the account itself reads and writes them, never the root agent, and stored files are
readable only by it. The host refuses a `get` larger than it asked for and deletes a partial file.

When it starts, before the user logs in, the agent copies the user's per-host preferences into
place for the Mac it runs on. macOS keeps some settings, such as when the screen saver starts,
per host, in files named after the hardware UUID, and every clone has a new one with its new
machine identifier, so a clone would otherwise start those settings from macOS's defaults. The
agent copies, as the user, the newest file of each setting from another UUID, and only where the
clone has none yet. It logs each one it copies to `/var/log/paddock-guestd.log`.

The folder also holds `paddock-session`, a LaunchAgent that runs in the desktop session of whoever
logs in to the guest, where the accessibility API can see apps. It listens only on vsock port
52526 and speaks the same protocol:

| Request | Answer |
| --- | --- |
| `{"op":"health"}` | `{"version":"0.2.0"}` |
| `{"op":"axtree"}` | `{"output":"..."}` for each line of the focused app's accessibility tree as JSON, then `{"exit":0}` |
| `{"op":"state"}` | `{"output":"desktop"}` once loginwindow has no window on screen, then `{"exit":0}` |

After a login, loginwindow covers the screen with a snapshot of the desktop until the Dock reports
the desktop ready, which took 3 s to over 20 s in testing. Until then screenshots show the
snapshot, and a click lands on loginwindow, which keeps the keyboard focus afterwards. `state`
reads only the owners of on-screen windows, which needs no permission.

Each element of the tree has its role, its subrole, title, value, description and identifier when
it has them, whether it is enabled and focused, its frame as x, y, width and height in screen
points from the top left of the display, and its children. Text is cut at 500 characters, and a
tree stops at 5,000 elements and 50 levels. Reading other apps needs the Accessibility
permission, which macOS grants per binary: `axtree` fails until paddock-session is allowed in
System Settings > Privacy & Security > Accessibility.

## Make a golden image and benchmark it

```bash
paddock install golden        # download the latest supported macOS and install it
paddock run golden            # finish Setup Assistant in the window
paddock bench golden --runs 3 # clone, boot headless, time each step, delete the clone
```

While Setup Assistant is open in `paddock run`, set up the guest the way every clone should be:

1. Create the user account. With macOS 27 on this Mac and in the VM, paddock can create it on
   the VM's first boot, in place of Setup Assistant, with automatic login and Remote Login on:

   ```bash
   paddock run golden --provision bench   # asks for the account's password on the terminal
   ```

   The license agreement and a welcome screen still appear once; the rest of Setup Assistant
   doesn't. macOS reads this only on the first boot after `paddock install`. paddock refuses
   this Mac's own user name, which provisioning is reported to fail on.
2. Install the guest agent. Boot with the staged `guest` folder shared, then run its installer
   in the guest's Terminal:

   ```bash
   paddock run golden --share .build/out/Products/Release/guest   # on the host
   sudo bash "/Volumes/My Shared Files/install.sh"                # in the guest
   ```

   The installer prints `paddock-guestd is running` when the agent is up, and
   `paddock-session is running` when the session helper is.
3. Give every clone a desktop that stays up and commands that never wait for a prompt. These
   are security settings, so they are yours to make (see
   [What a golden image allows](#what-a-golden-image-allows)):
   - Turn on automatic login for the user in System Settings > Users & Groups.
   - Stop sleep and the display turning off: `sudo pmset -a sleep 0 displaysleep 0`.
   - Set "Start Screen Saver when inactive" to Never in System Settings > Lock Screen. Clones
     keep the screen lock on whatever this image says (see [Limits](#limits)), so the screen
     saver and sleep, which would set it off, must stay off.
   - Allow `paddock-session` in System Settings > Privacy & Security > Accessibility. macOS asks
     when the installer starts it.
   - Add `/usr/local/libexec/paddock-guestd` in System Settings > Privacy & Security > Full Disk
     Access. Without it, a command that touches Desktop, Documents or Downloads waits for a
     prompt that nobody answers.

   macOS keeps both grants for rebuilt binaries only if they have the same signature:
   `scripts/build.sh` signs both with the code-signing certificate named in
   `PADDOCK_SIGNING_IDENTITY`, `paddock local signing` by default, and ad hoc if there is none,
   in which case every rebuild needs granting again. `serve` checks these settings in the
   clone it boots for its slot and warns about each one that is missing.
4. Shut down from the Apple menu. Closing the window or pressing Ctrl-C also asks the guest to
   shut down; doing it a second time forces the VM off.

## Commands

| Command | What it does |
| --- | --- |
| `paddock install <name> [--ipsw path] [--cpus 4] [--memory 8] [--disk-size 80]` | Finds the latest macOS this Mac supports, downloads it into the cache and installs it into a new VM. Memory and disk are in GB. |
| `paddock run <name> [--share folder] [--provision account [--full-name name]]` | Boots a VM in a window. `--share` mounts a host folder read-only in the guest; `--provision` creates the account on the first boot after `install`. |
| `paddock clone <source> <name>` | Makes an APFS copy-on-write clone with a fresh machine identifier and MAC address. |
| `paddock bench <source> [--runs 1] [--timeout 300] [--restore] [--userspace] [--keep]` | Clones the source, boots the clone headless, prints timings, then stops and deletes the clone. With `--restore`, each run restores a saved state instead of cold booting. With `--userspace`, each VM gets its own userspace network instead of the shared NAT, and there is no running step. |
| `paddock serve <source> [--userspace]` | Keeps one warm clone of the source running headless. At startup it boots a clone with the slot's own identity until it is ready and saves its state; each warm VM is a fresh clone restored from that state, handed out once it is ready again. A VM is ready once its guest agent answers and the guest reports an IPv4 address and an IPv4 DNS server, and, if the source has `paddock-session` installed, once the helper answers and says loginwindow has finished the login, which means the desktop takes input. A helper before 0.2.0 can't say, so `serve` then waits only for it to answer. If the warm VM stops, serve restores another. Ctrl-C stops it and deletes the slot's VMs. |
| `paddock acquire [--allow names]` | Takes the warm VM from `serve` and prints its name and address, waiting while the slot fills. With `serve --userspace`, the VM reaches only the names in `--allow`, comma-separated, and nothing without it (see [The userspace network](#the-userspace-network)); `--allow` against a `serve` on NAT fails. |
| `paddock exec <vm> -- <command>` | Runs a command in a VM that `acquire` handed out, through its guest agent over vsock, streams the output and exits with the command's status. The words after `--` are joined with spaces, as `ssh` does. |
| `paddock task <vm> --bundle <in> --result <out> -- <command>` | Copies a git bundle of a branch (made with `git bundle create <in> HEAD`) into the VM over vsock, clones it, runs the command in the clone and commits whatever it changed, authored as paddock, even if the command fails. New commits come back as a bundle at `<out>`, ready for `git fetch <out> HEAD:<branch>`; with none, it prints `No changes`. Exits with the command's status. |
| `paddock screenshot <vm> [-o file.png]` | Saves the screen of a VM that `acquire` handed out as a PNG, `<vm>.png` in the current folder by default. `serve` reads the VM's framebuffer on this Mac, so the guest grants nothing and runs nothing (see [Screenshots](#screenshots)). |
| `paddock axtree <vm>` | Prints the accessibility tree of the focused app in a VM that `acquire` handed out, as JSON, from `paddock-session` in the guest. Its frames are in the same coordinates as `paddock screenshot`'s pixels. |
| `paddock click <vm> <x> <y> [--right] [--double]` | Clicks at a point of the guest's screen, in pixels from the top left, as in `paddock screenshot` (see [Input](#input)). |
| `paddock type <vm> <text>` | Types text into whatever has the keyboard focus in the guest, as key presses. |
| `paddock key <vm> <combination>...` | Presses key combinations in turn, such as `cmd+s`, `cmd+shift+z` or `return`. |
| `paddock scroll <vm> <x> <y> [--down n] [--up n] [--right n] [--left n]` | Scrolls by about n lines at a point of the guest's screen. |
| `paddock release <vm>` | Hands a VM back to `serve`, which force-stops it, deletes the clone and restores a fresh one. |
| `paddock mcp` | Serves `serve`'s VMs to an agent as an MCP server on stdin and stdout (see [Agents over MCP](#agents-over-mcp)). |

These commands reach `serve` through `~/.paddock/serve.sock`, a Unix socket only its owner can
open. Each connection carries one request line of JSON and gets one or more answer lines back;
`exec` streams one per line of output, then the exit status. Only one `serve` can listen at a
time.

VMs live in `~/.paddock/vms` and restore images in `~/.paddock/cache/ipsw`. Set
`PADDOCK_HOME` to use another directory. A VM that is running is locked, so it can't be cloned
mid-write.

## Run a task from another Mac

`scripts/run-on-studio.sh` runs a command in a fresh VM on another Mac, on the current repo's
last commit, and brings what it commits back as a local branch. It needs only `git` and `ssh` on
the Mac you run it from. The other Mac needs Remote Login on for your account, `paddock serve`
running, and the Command Line Tools in its golden image for `git`.

```bash
scripts/run-on-studio.sh you@studio.local -- 'swift test'
```

The script bundles `HEAD`, copies it over one SSH connection, runs `acquire`, `task` and
`release` on the other Mac, and fetches any new commits as `paddock/<date-time>`. It releases the
VM, which wipes it, and removes its temporary files even when the command fails, then exits with
the command's status. Uncommitted changes stay where they are. Set `PADDOCK_REMOTE` if paddock
isn't at `~/code/paddock/.build/out/Products/Release/paddock` on the other Mac.

## Screenshots

`paddock screenshot` reads a VM's screen on the host, not in the guest. `serve` attaches a
`VZVirtualMachineView` to the VM, in a borderless window it places off every display, and copies
the frame that the view's framebuffer view keeps as an IOSurface. The guest needs no Screen
Recording permission, and paddock opens no listener and asks for no permission on the host. A
frame is the VM's display at its size in pixels, 1920×1200 by default, with the mouse pointer.
The first screenshot of a VM attaches the view and took about 150 ms in testing; later ones took
about 50 ms, mostly encoding the PNG.

- `serve` needs the window server for this, so start it from a logged-in session on the Mac. A
  `serve` that can't reach the window server refuses screenshots.
- Apple doesn't document that the view keeps its frame as an IOSurface. If a macOS release
  changes that, `screenshot` fails with an error saying what it couldn't find.
- The guest sends a frame only when its screen changes, so `serve` attaches each restored VM's
  display before the VM resumes and draws. A guest that doesn't redraw as it resumes still shows
  a black screen until its screen next changes: 2 of 10 hand-outs in testing.

## Input

`click`, `type`, `key` and `scroll` drive the guest from the host. `serve` sends mouse and
keyboard events to the `VZVirtualMachineView` it attaches for screenshots, and the guest gets them
from its virtual pointer and keyboard, so the guest grants nothing and runs nothing for them. A
command returns once its events are sent, not once the guest has acted on them; read the screen
or the accessibility tree to see the result.

- `type` and `key` press keys of a US keyboard, so the guest must use a US keyboard layout for
  text to come out as typed, and `type` refuses characters a US keyboard can't type, such as
  `é`. Apps still apply their own changes: TextEdit turns straight quotes into curly ones.
- A combination for `key` is modifiers and one key joined by `+`: modifiers are `cmd`, `ctrl`,
  `opt` and `shift`, and the key is a character, `plus` for `+`, or one of `return`, `tab`,
  `space`, `delete`, `forwarddelete`, `escape`, `left`, `right`, `up`, `down`, `home`, `end`,
  `pageup`, `pagedown` and `f1` to `f12`.
- Keys go at about 100 characters a second. The guest drops keys that go down and up much
  faster: typing 500 characters with no pause between key events, 163 arrived in testing.
- `scroll` directions are the content's with macOS's default natural scrolling. A golden image
  that turns natural scrolling off scrolls the other way.

## Agents over MCP

`paddock mcp` is an MCP server that an agent's client starts and talks to over stdin and stdout.
It reaches `serve` through its socket, like the other commands, so it runs on the Mac that runs
`serve`. From another Mac, start it through ssh, which must log in without a prompt, with a key:
an MCP client can't answer a password prompt. In Claude Code, for example:

```bash
claude mcp add paddock -- ~/code/paddock/.build/out/Products/Release/paddock mcp                 # on the Mac
claude mcp add paddock -- ssh you@studio.local code/paddock/.build/out/Products/Release/paddock mcp  # from another
```

| Tool | What it does |
| --- | --- |
| `acquire` | Takes the warm VM from `serve`, waiting while the slot fills. `allow` lists the names it may reach on the userspace network. |
| `screenshot` | The VM's screen as a PNG. |
| `accessibility_tree` | The focused app's accessibility tree as JSON, as `paddock axtree` prints it but on one line. |
| `click`, `type_text`, `press_keys`, `scroll` | Input, as with the commands of the same names (see [Input](#input)). |
| `run_command` | Runs a command as `paddock exec` does and returns its output and exit status. Output past 20,000 characters is cut to its last lines. After `timeout` seconds, 120 by default and at most 3,600, it returns what the command printed so far, and the command goes on running in the VM. |
| `release` | Hands the VM back to `serve`, which wipes it. |

- A session holds one VM at a time. When the client closes stdin, or stops the server with
  SIGINT, SIGTERM or SIGHUP, as a dropped ssh connection does, the server releases the VM it
  holds.
- Screenshots are scaled to fit 1280x800, keeping the screen's shape: 1920x1200 becomes
  1280x800. Every coordinate the tools take or return is in the screenshot's pixels, frames in
  the accessibility tree included, and the server converts them for the guest.
- What the tools return from the guest, its screen, tree and command output, is whatever the
  workload in the VM put there. An agent should trust it no more than the workload.

## What a golden image allows

A golden image set up as above gives up some of macOS's protections so that its VMs run with
nobody watching. They are the guest's protections, not this Mac's: the VM is the boundary
between a workload and the host, and every VM is wiped when it is released.

| Setting | What it allows |
| --- | --- |
| Automatic login | macOS keeps the account's password in `/etc/kcpassword`, obfuscated but reversible, so anyone with a copy of the image can recover it. |
| No screen saver or sleep | Whoever has the screen has the session: paddock's screenshots and input, by design. |
| Accessibility for `paddock-session` | It can read and drive the interface of every app in the session; `axtree` reads only the focused app's. |
| Full Disk Access for `paddock-guestd` | Commands it runs, through `exec`, `task` and `run_command`, can read and change every file in the guest, other apps' data included. |

- Give the golden image's account a password used nowhere else, and sign it in to nothing:
  every workload can read what the image holds.
- The grants are made by hand, once, in the golden image, so SIP stays on. paddock needs no
  Screen Recording permission, since it reads the screen on the host.
- A grant belongs to a binary's signature, so a workload that replaces `paddock-session` or
  `paddock-guestd` with its own binary doesn't get it. paddock treats both as untrusted anyway.
- `serve` warns about each setting missing from the clone it boots for its slot, with what to
  change. It doesn't change them itself.

## The userspace network

With `--userspace`, each VM's network is its own `paddock-net` process instead of macOS's shared
NAT. It gives the guest 192.168.127.2 by DHCP, on a lease that never expires, with the gateway
192.168.127.1 as its router and DNS server, and lets the guest reach only the names on its list.
A warm VM's list is empty.
`paddock acquire --allow github.com,*.githubusercontent.com` puts its list in force before
`serve` hands the VM out, through `net.sock`, a control socket paddock-net creates in the VM's
bundle that only you can open; a VM acquired without `--allow` reaches nothing. Releasing the VM
deletes it with its network. `bench --userspace` passes no list.

| What the guest sends | What paddock-net does |
| --- | --- |
| DNS to the gateway | A name on the list gets its IPv4 addresses from the host's resolver and no other records. Any other name has no such name (NXDOMAIN), with an SOA record that says not to cache the answer. No query is passed on to another server. |
| TCP to port 443 | Reads the server name from the TLS ClientHello. If it is on the list, connects to that name from the host and passes the connection through; the address the guest connected to is ignored. Otherwise closes it. |
| TCP to port 80 | The same, with the HTTP request's `Host` header. |
| TCP to any other port | Resets it. |
| NTP to the gateway | Answers with the host's time. `time.apple.com` resolves to the gateway whatever the list says, so macOS sets the guest's clock from it. |
| Anything else | Drops it: UDP other than DNS, NTP and DHCP to the gateway, so DNS sent to any other server too, and ICMP. |

An entry `example.com` matches that name only; `*.example.com` matches every name under it, but
not `example.com` itself. Connections from the host never go to a loopback or link-local address,
whatever a name resolves to, so the host's own services and EC2's instance metadata stay out of
reach. Nothing on the host's networks can open a connection to the guest. Each decision is one
line on paddock-net's stderr, which is `serve`'s or `bench`'s, such as `now allowing github.com`,
`allow github.com:443`, `deny example.com:443: not on the list` and `deny dns example.com: not
on the list`.

paddock-net doesn't decrypt TLS, so a client can name an allowed host in its ClientHello and then
ask that server for another site it also serves. Only ports 80 and 443 work, so git needs HTTPS
rather than SSH. HTTP/3 runs over UDP and is dropped; clients fall back to TCP.

A macOS guest's clock starts where golden's last shutdown left it, 3.6 hours behind in testing,
and a restored guest's where its state was saved. macOS sets it from paddock-net's NTP about
0.1 s after the guest's network comes back, so a VM `serve` hands out has the right time: 73 µs
off in testing. The lease never expires because of that jump: the slot's guest leases its
address before its clock moves forward, and an expired lease would make every restore go through
DHCP from the start, 1.6 s slower than reusing it.

A restored guest asks for about 20 Apple names and is refused. macOS keeps a denied name for
about 75 s whatever the answer says, so a name the warm guest looked up shortly before Assign,
such as one of those Apple names, can stay unresolvable for that long after its acquire allowed
it.

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
  aux.img      Mac auxiliary storage
  config.json  hardware model and machine identifier (base64), MAC address,
               CPU count, memory, disk size, display and the installed macOS build
  state.vzvmsave  optional saved memory and device state of a paused VM
  net.sock     paddock-net's control socket, while the VM runs on the userspace network
```

## Limits

- macOS allows at most two macOS VMs running at once on one host.
- Clones must be on the same APFS volume as their source. Cloning fails rather than copying.
- Networking is macOS's shared NAT, or with `--userspace` a network of each VM's own, where a
  VM reaches only the names its `acquire --allow` listed (see
  [The userspace network](#the-userspace-network)). It moves about 0.35 GB/s against about
  4 GB/s for NAT, measured downloading from the host.
- On the NAT network, a restored guest's traffic starts flowing 1 to 3 s after the guest
  reports its address and DNS server, so the first network request in a freshly handed-out VM
  can stall that long: the first DNS lookup took 0.8 to 2.0 s in testing, later ones about
  1 ms. Nothing the guest reports shows when its packets start getting through, so `serve`
  can't wait for it. The userspace network doesn't have the delay.
- Every clone has a new MAC address, so every boot takes a new lease from macOS's DHCP server,
  which keeps leases for a day. The NAT network has about 250 addresses, so a few hundred clone
  boots in one day exhaust it and new guests get no address. Shorten the lease time if you
  benchmark heavily:

  ```bash
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600
  ```
- `serve` has one slot with one identity, so every VM it hands out has the same MAC address and IP
  address. Each starts with its clock behind by the time since `serve` saved
  the slot's state, until macOS corrects it once the guest's network is back: from Apple's time
  servers on NAT, and from paddock-net on the userspace network.
- Clones always have macOS's screen lock on, whatever the golden image says: macOS keeps that
  setting with the machine's identity, which every clone changes, and turning it off takes the
  user's password. With no screen saver and no sleep nothing sets it off, but anything that
  starts the screen saver or locks the screen, such as Ctrl-Cmd-Q, locks the session until the
  password is typed. Release the VM to get a fresh one.
- Apple's macOS license permits macOS VMs for development and testing.

## License

Apache 2.0. See [LICENSE](LICENSE).
