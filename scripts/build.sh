#!/usr/bin/env bash
# Build paddock and ad-hoc sign it with the virtualization entitlement.
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

echo "$bin"
