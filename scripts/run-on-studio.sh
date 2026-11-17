#!/usr/bin/env bash
# Run a command on another Mac in a fresh paddock VM, on this repo's last commit, and bring
# whatever it commits back here as a branch. Needs only git and ssh on this Mac; the other Mac
# runs 'paddock serve'. The VM is released, and so wiped, even if the command fails.
#
# Usage: scripts/run-on-studio.sh <user@host> -- <command>
#   PADDOCK_REMOTE  path of paddock on the other Mac
#                   (default: ~/code/paddock/.build/out/Products/Release/paddock)
set -euo pipefail

if [[ $# -lt 3 || $2 != "--" ]]; then
  echo "usage: $0 <user@host> -- <command>" >&2
  exit 64
fi
host=$1
shift 2
command="$*"
# Left unquoted in remote commands on purpose, so the other Mac's shell expands ~.
paddock=${PADDOCK_REMOTE:-'~/code/paddock/.build/out/Products/Release/paddock'}

git rev-parse --git-dir >/dev/null
if [[ -n $(git status --porcelain) ]]; then
  echo "note: uncommitted changes stay here; the VM gets the last commit" >&2
fi

here=$(mktemp -d)
# One SSH connection for every step, so a password is asked for once. Files go through it with
# cat rather than scp, which doesn't reuse the connection.
ssh_options=(-o ControlMaster=auto -o "ControlPath=$here/ssh" -o ControlPersist=60)
remote=""
vm=""
cleanup() {
  if [[ -n $vm ]]; then
    ssh "${ssh_options[@]}" "$host" "$paddock release $vm" >/dev/null || true
  fi
  if [[ -n $remote ]]; then
    ssh "${ssh_options[@]}" "$host" "rm -rf $remote" || true
  fi
  ssh "${ssh_options[@]}" -O exit "$host" 2>/dev/null || true
  rm -rf "$here"
}
trap cleanup EXIT

# Quote for the remote shell: wrap in single quotes, each ' becomes '\''. The replacement sits
# in a variable because macOS's bash 3.2 mangles backslashes written inline there.
quote() {
  local escaped="'\\''"
  printf "'%s'" "${1//\'/$escaped}"
}

git bundle create -q "$here/in.bundle" HEAD
remote=$(ssh "${ssh_options[@]}" "$host" 'mktemp -d')
ssh "${ssh_options[@]}" "$host" "cat > $remote/in.bundle" < "$here/in.bundle"

vm=$(ssh "${ssh_options[@]}" "$host" "$paddock acquire" | sed -n "s/^Assigned '\([^']*\)'.*/\1/p")
if [[ -z $vm ]]; then
  echo "error: no VM from paddock serve on $host; is it running?" >&2
  exit 1
fi
echo "Running in $vm on $host" >&2

status=0
ssh "${ssh_options[@]}" "$host" \
  "$paddock task $vm --bundle $remote/in.bundle --result $remote/out.bundle -- $(quote "$command")" || status=$?

if ssh "${ssh_options[@]}" "$host" "test -f $remote/out.bundle"; then
  branch="paddock/$(date +%Y%m%d-%H%M%S)"
  ssh "${ssh_options[@]}" "$host" "cat $remote/out.bundle" > "$here/out.bundle"
  git fetch -q "$here/out.bundle" "HEAD:refs/heads/$branch"
  echo "New commits on branch $branch:" >&2
  git --no-pager log --oneline "HEAD..$branch" >&2
fi
exit "$status"
