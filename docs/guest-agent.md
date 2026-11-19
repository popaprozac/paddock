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
