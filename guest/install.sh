#!/bin/bash
# Install paddock-guestd in this macOS guest as a LaunchDaemon, and paddock-session as a
# LaunchAgent for whoever logs in to the desktop. Run it once in the golden image, from the folder
# 'paddock run --share' mounts: sudo ./install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo" >&2
  exit 1
fi
# paddock-guestd and paddock-session are built for macOS 14 and later, and won't start on older.
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then
  echo "error: paddock's guest agent needs macOS 14 or later, and this is $(sw_vers -productVersion)" >&2
  exit 1
fi
here="$(cd "$(dirname "$0")" && pwd)"

install -d -m 755 /usr/local/libexec
install -m 755 "$here/paddock-guestd" /usr/local/libexec/paddock-guestd
# Files copied from the host may carry quarantine, which stops launchd from running them.
xattr -c /usr/local/libexec/paddock-guestd
install -m 644 "$here/paddock.guestd.plist" /Library/LaunchDaemons/paddock.guestd.plist
install -m 755 "$here/paddock-session" /usr/local/libexec/paddock-session
xattr -c /usr/local/libexec/paddock-session
install -m 644 "$here/paddock.session.plist" /Library/LaunchAgents/paddock.session.plist

launchctl bootout system/paddock.guestd 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/paddock.guestd.plist
sleep 1
if launchctl print system/paddock.guestd | grep -q 'state = running'; then
  echo "paddock-guestd is running"
else
  echo "error: paddock-guestd is not running; see /var/log/paddock-guestd.log" >&2
  exit 1
fi

# Start paddock-session now in the desktop session of the user who ran sudo; otherwise launchd
# starts it at their next login.
uid="$(id -u "${SUDO_USER:-}" 2>/dev/null || true)"
if [[ -n "$uid" ]] && launchctl print "gui/$uid" >/dev/null 2>&1; then
  launchctl bootout "gui/$uid/paddock.session" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" /Library/LaunchAgents/paddock.session.plist
  # A session still logging in, as on a build's first boot while the guest finishes booting,
  # can't keep it up yet; launchd starts it again every 10 s, so give it a minute.
  for _ in $(seq 1 60); do
    launchctl print "gui/$uid/paddock.session" 2>/dev/null | grep -q 'state = running' && break
    sleep 1
  done
  if launchctl print "gui/$uid/paddock.session" | grep -q 'state = running'; then
    echo "paddock-session is running; allow it in System Settings > Privacy & Security > Accessibility"
  else
    echo "error: paddock-session is not running; see /tmp/paddock-session.log" >&2
    exit 1
  fi
else
  echo "paddock-session starts at the next desktop login"
fi
