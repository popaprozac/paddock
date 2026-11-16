#!/bin/bash
# Install paddock-guestd in this macOS guest as a LaunchDaemon. Run it once in the golden
# image, from the folder 'paddock run --share' mounts: sudo ./install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "error: run with sudo" >&2
  exit 1
fi
here="$(cd "$(dirname "$0")" && pwd)"

install -d -m 755 /usr/local/libexec
install -m 755 "$here/paddock-guestd" /usr/local/libexec/paddock-guestd
# Files copied from the host may carry quarantine, which stops launchd from running them.
xattr -c /usr/local/libexec/paddock-guestd
install -m 644 "$here/paddock.guestd.plist" /Library/LaunchDaemons/paddock.guestd.plist

launchctl bootout system/paddock.guestd 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/paddock.guestd.plist
sleep 1
if launchctl print system/paddock.guestd | grep -q 'state = running'; then
  echo "paddock-guestd is running"
else
  echo "error: paddock-guestd is not running; see /var/log/paddock-guestd.log" >&2
  exit 1
fi
