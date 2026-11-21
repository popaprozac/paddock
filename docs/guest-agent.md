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
| `{"op":"health"}` | `{"version":"0.6.0"}` |
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
readable only by it. The host refuses a `get` larger than it asked for and deletes a partial file.

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
| `{"op":"health"}` | `{"version":"0.2.1"}` |
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

## Linux guests

`paddock-guestd` for Linux guests, from `paddock-guestd-linux/`, speaks the same protocol on the
same port, and closes connections that don't come from CID 2 in the same way. `scripts/build.sh`
stages it in the `guest` folder's `linux` folder with `paddock-guestd.service`, and `paddock build`
installs both from its cloud-init seed (see [Linux images](golden-images.md#linux-images)): the
binary at `/usr/local/libexec/paddock-guestd` and the unit in `/etc/systemd/system`, enabled.
systemd runs the agent as root and starts it again if it exits. It logs to the journal. Its
`health` answers `{"version":"0.1.0"}`. Where it differs from the macOS agent:

- `run` uses a login bash (`bash -l`) as the account with uid 1000, in its home folder, with
  stdin closed, and with `"as":"root"` as root in `/root`. A command that a signal ends exits with
  128 plus the signal's number, as a shell reports it.
- `state` answers `{"output":"network"}` once an interface other than loopback has an IPv4
  address and the guest an IPv4 DNS server, from systemd-resolved's list of servers when it runs,
  else from `/etc/resolv.conf`. There is no session helper.
- `state` also answers `{"output":"desktop"}` once the account's desktop is up: the screen's
  driver is loaded (`/dev/dri/card0`), a keyboard and a pointer are in `/proc/bus/input/devices`,
  systemd-logind has an active, unlocked X11 or Wayland session for uid 1000, and the desktop has
  drawn: its shell runs as the account (xfdesktop, gnome-shell, plasmashell, cinnamon, mate-panel,
  budgie-panel, lxqt-panel or lxpanel), or, for another desktop, the session has been up for 5 s.
  `serve` waits for it on a desktop image before saving a slot's state.
- `{"op":"clock","time":N}`, with N in nanoseconds since 1970, sets the guest's clock and answers
  `{"exit":0}`. `paddock build` sends it at each boot, since a cloud image boots at 1970, and
  `serve` once each warm VM is ready, since a restored guest resumes at the time its state was
  saved.
- `{"op":"axtree"}` answers the accessibility tree of the app in front on the desktop, as
  paddock-session does on macOS: `{"output":"..."}` for each line of it as JSON, then
  `{"exit":0}`. The agent runs itself again as the account and reads its desktop's AT-SPI bus,
  `/run/user/1000/at-spi/bus_0`, which needs `at-spi2-core` in the image. The app in front is the
  one with an active window at least partly on screen. Each element has its role, in AT-SPI's
  names such as `push button`, its name as title, its text or number as value, its description
  and identifier when it has them, its frame as x, y, width and height in screen pixels from the
  top left, which it leaves out for an element off screen, whether it is enabled and focused, and
  its children, with macOS's limits. A call an app takes over 0.5 s to answer is left out.
- It doesn't copy per-host preferences, which are macOS's.
