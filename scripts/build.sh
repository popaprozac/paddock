#!/usr/bin/env bash
# Build paddock and ad-hoc sign it with the virtualization entitlement, and stage the guest
# agent's and session helper's files in a 'guest' folder next to it.
# Usage: scripts/build.sh [debug|release]   (default: release)
# Prints the path of the signed binary on success.
set -euo pipefail

config="${1:-release}"
case "$config" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 64 ;;
esac

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: paddock needs Apple silicon to run macOS guests" >&2
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$config" >&2
bin="$(swift build -c "$config" --show-bin-path)/paddock"

# Virtualization.framework refuses to start VMs without this entitlement.
codesign --force --sign - --entitlements "$root/paddock.entitlements" "$bin" >&2
codesign --verify --strict "$bin"
if ! codesign -d --entitlements - "$bin" 2>/dev/null | grep -q com.apple.security.virtualization; then
  echo "error: entitlement missing from $bin" >&2
  exit 1
fi

# paddock-net, each VM's userspace network stack, is Go and sits next to paddock.
if ! command -v go >/dev/null; then
  echo "error: paddock-net needs Go (https://go.dev/dl)" >&2
  exit 1
fi
(cd "$root/paddock-net" && go build -trimpath -o "$(dirname "$bin")/paddock-net" .) >&2

# paddock-session needs Accessibility in the guest, which macOS grants per signature. Signed with
# a stable certificate, a rebuilt helper keeps the grant; signed ad hoc, every build needs it again.
identity="${PADDOCK_SIGNING_IDENTITY:-paddock local signing}"
if security find-identity -p codesigning | grep -qF "\"$identity\""; then
  codesign --force --sign "$identity" "$(dirname "$bin")/paddock-session" >&2
else
  echo "note: no '$identity' code-signing certificate, so paddock-session is signed ad hoc;" \
    "allow it in golden's Accessibility settings again after every build" >&2
fi

# Stage the guest agent with its launchd job and installer, for 'paddock run --share'.
guest="$(dirname "$bin")/guest"
rm -rf "$guest"
mkdir -p "$guest"
cp "$(dirname "$bin")/paddock-guestd" "$(dirname "$bin")/paddock-session" \
  "$root/guest/paddock.guestd.plist" "$root/guest/paddock.session.plist" "$root/guest/install.sh" "$guest/"
echo "guest agent files: $guest" >&2

echo "$bin"
