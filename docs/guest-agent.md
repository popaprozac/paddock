# The guest agent

`scripts/build.sh` puts `paddock-guestd`, the agent that runs inside each guest, in a `guest`
folder next to the binary, with its launchd job and `install.sh`, which needs macOS 14 or later in
the guest. The agent listens only on
vsock port 52525 and answers only the host: a process in the guest can reach the guest's own
vsock ports, so the agent closes, unread, any connection that doesn't come from the host's vsock
address (CID 2), and logs it. An image whose agent is older than 0.5.1, or whose
`paddock-session` is older than 0.2.1, answers its own guest too: reinstall the guest agent in it
to close that. Each connection carries one request line of JSON and gets one or more answer lines
back:

| Request | Answer |
| --- | --- |
| `{"op":"health"}` | `{"version":"0.6.1"}` |
| `{"op":"run","command":"..."}` | `{"output":"..."}` for each line of the command's combined stdout and stderr, then `{"exit":N}` |
| `{"op":"run","command":"...","as":"root"}` | The same, with the command run as root |
| `{"op":"put","name":"...","size":N}` followed by N bytes | `{"exit":0}` once the file is stored |
| `{"op":"get","name":"..."}` | `{"chunk":n}` followed by n bytes, repeated, then `{"exit":0}` |
| `{"op":"state"}` | `{"output":"network"}` once en0 has an IPv4 address and the guest an IPv4 DNS server, `{"output":"session-helper"}` if `paddock-session` is installed, then `{"exit":0}` |

`run` uses a login shell (`zsh -l`) as the account with uid 501, the one created in Setup
Assistant, in its home folder, with stdin closed. With `"as":"root"` it runs as root instead,
also in a login shell, which paddock asks for only while it builds an image; since the agent
answers only the host, nothing in the guest can ask. An agent before 0.6.0 ignores `as` and runs
the command as the account. Output lines over 8 KB are split. `put` and
`get` work on files in that account's `~/paddock` folder, named by one plain path component, up
to 4 GiB; the account itself reads and writes them, never the root agent, and stored files are
readable only by it. A `put` the guest can't store, as on a full disk, fails saying so, and the
agent goes on; one before 0.6.1 was killed by it, and launchd restarted it, which cut off every
command running through it. The host refuses a `get` larger than it asked for and deletes a
partial file.

When it starts, before the user logs in, the agent copies the user's per-host preferences into
place for the Mac it runs on. macOS keeps some settings, such as when the screen saver starts,
per host, in files named after the hardware UUID, and every clone has a new one with its new
machine identifier, so a clone would otherwise start those settings from macOS's defaults. The
agent copies, as the user, the newest file of each setting from another UUID, and only where the
clone has none yet. It logs each one it copies to `/var/log/paddock-guestd.log`.

The folder also holds `paddock-session`, a LaunchAgent that runs in the desktop session of whoever
logs in to the guest, where the accessibility API can see apps. It listens only on vsock port
52526, answers only the host in the same way, and speaks the same protocol:

| Request | Answer |
| --- | --- |
| `{"op":"health"}` | `{"version":"0.2.3"}` |
| `{"op":"axtree"}` | `{"output":"..."}` for each line of the focused app's accessibility tree as JSON, then `{"exit":0}` |
| `{"op":"state"}` | `{"output":"desktop"}` once loginwindow has no window on screen, then `{"exit":0}` |
| `{"op":"front"}` | `{"output":"Finder, in place of Accessibility"}` when it made Finder the app in front, or else the app in front, then `{"exit":0}` |

After a login, loginwindow covers the screen with a snapshot of the desktop until the Dock reports
the desktop ready, which took 3 s to over 20 s in testing. Until then screenshots show the
snapshot, and a click lands on loginwindow, which keeps the keyboard focus afterwards. `state`
reads only the owners of on-screen windows, which needs no permission.

At some logins macOS lets AccessibilityUIServer, which it starts for an accessibility service and
which has no window, become the app in front. There it takes the keyboard, and every tree
describes it, until a click moves it, and a VM's saved state keeps it there. `front` makes Finder
the app in front when the app there isn't one people use, through the accessibility API, so no
window opens. `serve` asks for it once the desktop is up, before it saves a slot's state, and logs
when it had to. A helper before 0.2.3 can't, so about half the slots of an image that has one start
that way: reinstall the guest agent in it.

Each element of the tree has its role, its subrole, title, value, description and identifier when
it has them, whether it is enabled and focused, its frame as x, y, width and height in screen
points from the top left of the display, and its children. An element whose frame isn't a finite
rectangle, as an app's null rectangle isn't, has no frame; a helper before 0.2.2 quits on one
instead, and `axtree` fails while that app is in front. Text is cut at 500 characters, and a
tree stops at 5,000 elements and 50 levels. Reading other apps needs the Accessibility
permission, which macOS grants per binary: `axtree` fails until paddock-session is allowed in
System Settings > Privacy & Security > Accessibility.

## Linux guests

`paddock-guestd` for Linux guests, from `paddock-guestd-linux/`, speaks the same protocol on the
same port, and closes connections that don't come from CID 2 in the same way. `scripts/build.sh`
stages it in the `guest` folder's `linux` folder with `paddock-guestd.service`, and `paddock build`
installs both from its cloud-init seed (see [Linux images](golden-images.md#linux-images)): the
binary at `/usr/local/libexec/paddock-guestd` and the unit in `/etc/systemd/system`, enabled.
systemd runs the agent as root and starts it again if it exits. It logs to the journal. Its
`health` answers `{"version":"0.1.2"}`. Where it differs from the macOS agent:

- `run` uses a login bash (`bash -l`) as the account with uid 1000, in its home folder, with
  stdin closed, and with `"as":"root"` as root in `/root`. A command that a signal ends exits with
  128 plus the signal's number, as a shell reports it. Each command runs in a process group of its
  own, so one that signals its group, as `trap 'kill 0' EXIT` does, ends only itself; an agent
  before 0.1.2 was ended with it, which cut off every command running through it.
- A `put` the guest can't store fails saying so, as on macOS; an agent before 0.1.2 said instead
  that the upload stopped short.
- `state` answers `{"output":"network"}` once an interface other than loopback has an IPv4
  address and the guest an IPv4 DNS server, from systemd-resolved's list of servers when it runs,
  else from `/etc/resolv.conf`. There is no session helper.
- `state` also answers `{"output":"desktop"}` once the account's desktop is up: the screen's
  driver is loaded (`/dev/dri/card0`), a keyboard and a pointer are in `/proc/bus/input/devices`,
  systemd-logind has an active, unlocked X11 or Wayland session for uid 1000, and the desktop has
  drawn and takes input: its shell runs as the account (xfdesktop, gnome-shell, plasmashell,
  cinnamon, mate-panel, budgie-panel, lxqt-panel or lxpanel), or, for another desktop, the session
  has been up for 5 s. GNOME Shell runs from the start of its session, but covers the screen with
  an actor that swallows input until its startup animation is over, when it logs "GNOME Shell
  started" to the journal with `MESSAGE_ID=f3ea493c22934e26811cd62abe8e203a`. So for GNOME the
  agent waits for that entry in this boot's journal, or for the session to have been up for 60 s,
  should a GNOME stop logging it. `serve` waits for the desktop on a desktop image before saving a
  slot's state, so a VM restored from that state takes input at once. An agent before 0.1.1
  counts GNOME up early, and its VMs drop a click sent in their first second: rebuild a GNOME
  image to get the new agent.
- `{"op":"clock","time":N}`, with N in nanoseconds since 1970, sets the guest's clock and answers
  `{"exit":0}`. `paddock build` sends it at each boot, since a cloud image boots at 1970, and
  `serve` once each warm VM is ready, since a restored guest resumes at the time its state was
  saved.
- `{"op":"axtree"}` answers the accessibility tree of the app in front on the desktop, as
  paddock-session does on macOS: `{"output":"..."}` for each line of it as JSON, then
  `{"exit":0}`. The agent runs itself again as the account and reads its desktop's AT-SPI bus,
  `/run/user/1000/at-spi/bus_0` (`bus` on Ubuntu), which needs `at-spi2-core` in the image. The
  app in front is the one with an active window at least partly on screen. Each element has its
  role, in AT-SPI's names such as `push button`, its name as title, its text or number as value,
  its description and identifier when it has them, its frame as x, y, width and height in screen
  pixels from the top left, which it leaves out for an element off screen, whether it is enabled
  and focused, and its children, with macOS's limits. A call an app takes over 0.5 s to answer is
  left out, and `axtree` fails if the whole tree takes over 30 s; an agent before 0.1.2 waited as
  long as the desktop's bus did. Under Wayland, apps put every frame at 0, 0 with the right size, since they don't know
  where their windows are.
- It doesn't copy per-host preferences, which are macOS's.

## Windows guests

`paddock-guestd` for Windows guests, from `paddock-guestd-windows/`, is Go built for
windows/arm64. It speaks the same protocol on the same port, through virtio-win's viosock driver
and its Winsock provider, and closes connections that don't come from CID 2 in the same way.
`scripts/build.sh` stages it in the `guest` folder's `windows` folder with `install.ps1`, which
installs it at `C:\Program Files\paddock\paddock-guestd.exe` as the Windows service
`paddock-guestd` (see [Windows images](golden-images.md#windows-images)). The service runs it as
SYSTEM from boot, and the service manager starts it again a second after it dies or stops with an
error, as it does when vsock isn't up yet early in a boot. Its log goes nowhere yet. Its `health`
answers `{"version":"0.5.1"}`; an agent before 0.5.0 ran from a scheduled task that never started
it again. Where it differs from the Linux agent:

- `run` uses `cmd.exe /d /s /c` as the account signed in at the console, with its environment, in
  its profile folder, on its desktop, so a window the command opens shows on the screen. An
  administrator gets two tokens when it signs in: a filtered one with a standard user's rights,
  which what it starts gets, and an elevated one, which Windows hands out after a UAC prompt.
  Commands get the elevated one, as a Linux workload account has sudo with no password, so whatever
  a workload runs can act as an administrator in its own VM, which is wiped when it is released.
  What the account opens by clicking still gets the filtered token, and Windows stops some input
  from a standard window to an elevated one, such as dragging a file onto it. With `"as":"root"` a
  command runs as SYSTEM. Output comes back without its CR LF line endings.
- `put` and `get` work on files in the account's `%USERPROFILE%\paddock` folder. The agent opens
  them while it impersonates the account, never as SYSTEM, so a link planted in the folder
  reaches only what the account could reach. Files take the profile's permissions: the account,
  SYSTEM and administrators. A name is one plain name that Windows keeps as given: no separators,
  colons, wildcards, control characters or leading dot, no trailing dot or space, which Windows
  drops, and no device name, such as `NUL`, `CON` or `COM1`, with or without an extension. An
  agent before 0.5.1 said a file the guest couldn't store stopped short.
- `state` answers `{"output":"network"}` once an adapter that is up, other than loopback, has an
  IPv4 address and an IPv4 DNS server, and its traffic gets through: its IPv4 gateway answers a
  ping within 0.5 s, or the adapter received something meanwhile, as on a network whose gateway
  ignores pings. After Virtualization.framework restores a saved state, virtio-win's NetKVM
  driver sends but receives nothing until its adapter restarts, so the agent disables and enables
  an adapter that received nothing during an unanswered ping, at most every 15 s, with `netsh`.
- `state` also answers `{"output":"desktop"}` once a session other than session 0 is active and
  runs `explorer.exe`. It doesn't check that the session is unlocked, so an image signs in by
  itself and never locks.
- `clock` sets the guest's clock as the Linux agent's does, and `serve` sends it to each warm
  Windows VM once it's ready.
- `axtree` answers the tree of the app in front, in the same shape. UI Automation reads only the
  desktop of the session it runs in, so the agent runs itself again as the account, with the
  account's elevated token, in its session. The app in front is the process whose window is in
  front, with all of that process's windows on screen, and the tree is UI Automation's control
  view of them. The root is an `Application` element titled with the program's name, such as
  `Notepad`. Each element has UI Automation's control type as its role, such as `Button`, `Edit`
  or `Document`, its name as title, its text or number as value (for a document, its first 500
  characters), its help text as description and its automation id as identifier when it has them,
  its frame as x, y, width and height in screen pixels from the top left, which it leaves out for
  an element off screen, whether it is enabled and has the keyboard focus, and its children, with
  macOS's limits. A packaged app whose windows belong to ApplicationFrameHost, such as Settings,
  comes with that host's other windows on screen.
- It doesn't copy per-host preferences, which are macOS's.
