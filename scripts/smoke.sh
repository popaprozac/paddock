#!/usr/bin/env bash
# Smoke-tests paddock on this Mac, one supported image at a time: builds it from its template,
# serves it, acquires a VM and runs a command in it. Where it has a screen, it also takes a
# screenshot, opens an app with input, types a marker into it and finds the marker in the
# accessibility tree. Then it releases the VM and deletes the image.
#
# It runs in a paddock home of its own, so your images and any serve you run are left alone;
# downloads go through your cache. It prints a table to paste into a PR, keeps each image's logs
# and screenshots in the folder it names, and exits non-zero if any image failed.
#
# Usage: scripts/smoke.sh [--macos <image>] [template ...]
#   template  debian, debian-desktop, ubuntu or ubuntu-desktop; all four when none is named
#   --macos   also test this macOS image from your paddock home, cloned in: a macOS build needs
#             a password, so the script doesn't make one
#   PADDOCK   a paddock binary to test, instead of building one with scripts/build.sh
set -uo pipefail

usage="usage: $0 [--macos <image>] [debian|debian-desktop|ubuntu|ubuntu-desktop ...]"
root=$(cd "$(dirname "$0")/.." && pwd)
user_home=${PADDOCK_HOME:-$HOME/.paddock}
macos=""
templates=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --macos) macos=${2:?$usage}; shift 2 ;;
    debian | debian-desktop | ubuntu | ubuntu-desktop) templates+=("$1"); shift ;;
    *) echo "$usage" >&2; exit 64 ;;
  esac
done
[[ ${#templates[@]} -eq 0 ]] && templates=(debian debian-desktop ubuntu ubuntu-desktop)
if [[ -n $macos && ! -d $user_home/vms/$macos ]]; then
  echo "no image named '$macos' in $user_home/vms" >&2
  exit 1
fi

out=$(mktemp -d -t paddock-smoke)
if [[ -n ${PADDOCK:-} ]]; then
  paddock=$PADDOCK
else
  echo "Building paddock"
  paddock=$("$root/scripts/build.sh" 2>"$out/build.log" | tail -1) || {
    echo "scripts/build.sh failed: see $out/build.log" >&2
    exit 1
  }
fi

home=$out/home
mkdir -p "$home/vms" "$user_home/cache"
ln -s "$user_home/cache" "$home/cache"
export PADDOCK_HOME=$home PADDOCK_LOCAL=1

serve_pid=""
vm=""
stop_serve() {
  if [[ -n $vm ]]; then
    "$paddock" release "$vm" >/dev/null 2>&1
    vm=""
  fi
  if [[ -n $serve_pid ]]; then
    kill -INT "$serve_pid" 2>/dev/null
    for _ in $(seq 120); do kill -0 "$serve_pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "$serve_pid" 2>/dev/null
    wait "$serve_pid" 2>/dev/null
    serve_pid=""
  fi
}
trap 'stop_serve; rm -rf "$home"' EXIT
trap 'exit 130' INT TERM

# Runs a command, killing it after the given seconds, since macOS has no timeout(1).
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' "$@"; }

seconds() { if (($1 >= 60)); then echo "$(($1 / 60))m $(($1 % 60))s"; else echo "$1s"; fi; }

# Checks one image, setting the table's columns as it goes and step to the step that's running.
# kind: linux (no screen), xfce, gnome or macos.
check() {
  local name=$1 kind=$2 dir=$3 started acquired
  if [[ $kind == macos ]]; then
    step=clone
    cp -c -R "$user_home/vms/$name" "$home/vms/" || return 1
    build=cloned
  else
    step=build
    started=$SECONDS
    "$paddock" init "$dir/$name.yaml" --template "$name" >/dev/null || return 1
    "$paddock" build "$dir/$name.yaml" >"$dir/build.log" 2>&1 || return 1
    build=$(seconds $((SECONDS - started)))
  fi

  step=serve
  "$paddock" serve "$name" --slots 1 >"$dir/serve.log" 2>&1 &
  serve_pid=$!
  for _ in $(seq 120); do
    [[ -S $home/serve.sock ]] && break
    kill -0 "$serve_pid" 2>/dev/null || return 1
    sleep 0.5
  done
  step=acquire
  acquired=$(limit 900 "$paddock" acquire 2>"$dir/acquire.err") || return 1
  vm=$(sed -nE "s/^Assigned '([^']+)'.*/\1/p" <<<"$acquired")
  [[ -n $vm ]] || return 1
  boot=$(sed -nE 's/^  slot 1 booted at .* in (.*), saved .*/\1/p' "$dir/serve.log" | head -1)
  warm=$(sed -nE "s/^Slot 1 warm: '[^']*' at [^,]*, (.*)/\1/p" "$dir/serve.log" | head -1)

  step=exec
  local command="uname -sr"
  [[ $kind == macos ]] && command="sw_vers -productVersion"
  os=$(limit 60 "$paddock" exec "$vm" -- "$command" 2>"$dir/exec.err" | tail -1) || return 1

  if [[ $kind != linux ]]; then
    step=screenshot
    limit 60 "$paddock" screenshot "$vm" -o "$dir/screen.png" >/dev/null 2>"$dir/screenshot.err" || return 1
    screen=$(sips -g pixelWidth -g pixelHeight "$dir/screen.png" |
      awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { if (w) print w "x" h }')
    [[ -n $screen ]] || return 1

    step=input
    local marker="paddock smoke $RANDOM"
    case $kind in
      xfce) "$paddock" key "$vm" ctrl+alt+t ;;  # a terminal
      gnome)  # Activities, then the text editor, once the search has caught up with the typing
        "$paddock" click "$vm" 35 15 && sleep 1.5 && "$paddock" type "$vm" "text editor" &&
          sleep 3 && "$paddock" key "$vm" return ;;
      macos) "$paddock" key "$vm" cmd+shift+g ;;  # Finder's Go to Folder
    esac >/dev/null 2>"$dir/input.err" || return 1
    sleep 3
    "$paddock" type "$vm" "$marker" >/dev/null 2>>"$dir/input.err" || return 1

    step=tree
    for _ in $(seq 20); do
      limit 30 "$paddock" axtree "$vm" >"$dir/tree.json" 2>"$dir/tree.err" && grep -q "$marker" "$dir/tree.json" && break
      sleep 1
    done
    grep -q "$marker" "$dir/tree.json" || return 1
    tree="$(jq -r '"\([.. | objects | select(has("role"))] | length) elements in \(.title // .role)"' "$dir/tree.json")" ||
      return 1
    limit 60 "$paddock" screenshot "$vm" -o "$dir/typed.png" >/dev/null 2>&1
  fi

  step=release
  limit 60 "$paddock" release "$vm" >/dev/null 2>"$dir/release.err" || return 1
  vm=""
}

rows=()
failed=0
smoke() {
  local name=$1 kind=$2 dir=$out/$1 result
  build=- boot=- warm=- os=- screen=- tree=-
  mkdir -p "$dir"
  echo "Testing $name"
  if check "$name" "$kind" "$dir"; then result=pass; else result="**failed at $step**"; failed=1; fi
  stop_serve
  rm -rf "${home:?}/vms/$name"
  rows+=("| $name | $build | $boot | $warm | $os | $screen | $tree | $result |")
  echo "  $result"
}

for template in "${templates[@]}"; do
  case $template in
    debian-desktop) smoke "$template" xfce ;;
    ubuntu-desktop) smoke "$template" gnome ;;
    *) smoke "$template" linux ;;
  esac
done
[[ -n $macos ]] && smoke "$macos" macos

commit=$(git -C "$root" rev-parse --short HEAD)
[[ -n $(git -C "$root" status --porcelain --untracked-files=no) ]] && commit+=" with uncommitted changes"
{
  echo "Smoke test of $commit on $(sysctl -n hw.model), macOS $(sw_vers -productVersion), $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "| Image | Build | Boot | Warm | OS | Screen | Tree | Result |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
} | tee "$out/summary.md"
echo
echo "Logs and screenshots: $out"
exit $failed
