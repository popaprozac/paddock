# Building and testing

## Requirements

- An Apple silicon Mac running macOS 14 or later.
- Swift 6 from Xcode or the Command Line Tools.
- Go, for `paddock-net`, `paddock-control` and the Linux and Windows guest agents. `paddock-net`'s dependencies need Go 1.26; with an older Go installed, Go fetches
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
when `bench` or `serve` runs with `--userspace` (see [The userspace network](network.md)).
It is Go, on [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock), with its module
in `paddock-net/`. Run its checks with `go vet ./...` and `go test ./...` there.

It builds `paddock-control` there as well: the control plane, which knows every Mac in a pool
(see [A pool of Macs](control-plane.md)). It is Go too, with its module in
`paddock-control/`, and builds for Linux with `GOOS=linux go build`. Run its checks the same way.

Last, it builds the guest agent for Linux guests, `paddock-guestd` from `paddock-guestd-linux/`:
Go, built static for arm64 Linux. Its dependencies are godbus (`github.com/godbus/dbus/v5`),
for AT-SPI's D-Bus, and `golang.org/x/sys`, which godbus needs. It goes in the `guest` folder's
`linux` folder with its systemd unit (see [Linux guests](guest-agent.md#linux-guests)). Its tests
run on the Mac with `go test ./...` there, and `GOOS=linux go vet ./...` checks the Linux-only
vsock code.

The guest agent for Windows guests, `paddock-guestd.exe` from `paddock-guestd-windows/`, is Go
too, with `golang.org/x/sys` as its only dependency. Build it for Windows on Arm with
`GOOS=windows GOARCH=arm64 go build` there; `scripts/build.sh` doesn't build it yet, and an image
installs it by hand (see [Windows images](golden-images.md#windows-images)). Its tests run on the
Mac with `go test ./...` there, and `GOOS=windows go vet ./...` checks the Windows-only code.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

- `swift build` and `swift test` on GitHub's `xcode-27` runner, since paddock uses macOS 27's
  SDK.
- `go vet ./...` and `go test ./...` in each Go module on `macos-latest`, then
  `GOOS=linux go build ./...` in `paddock-control`, `GOOS=linux go vet ./...` in
  `paddock-guestd-linux` and `GOOS=windows go vet ./...` in `paddock-guestd-windows`.

GitHub's Mac runners are VMs themselves and can't start VMs, so CI runs the unit tests only.
Anything that boots a VM, such as `build`, `serve` and the guest agents, is tested on a Mac with
the smoke test.

## Smoke test

`scripts/smoke.sh` tests the [supported images](../README.md#supported-images) end to end on
this Mac, one at a time. It builds each from its template, serves it with one slot, acquires a
VM and runs a command in it. Where the image has a screen, it also takes a screenshot, opens an
app with input (a terminal on Xfce, the text editor on GNOME, Go to Folder in Finder on macOS),
types a marker and finds it in the accessibility tree. Then it releases the VM and deletes the
image.

```bash
scripts/smoke.sh --macos golden
```

- It builds paddock with `scripts/build.sh` first, or tests the binary that `PADDOCK` names.
- It tests the `debian`, `debian-desktop`, `ubuntu` and `ubuntu-desktop` templates, or the ones
  you name. `--macos <image>` adds a macOS image from the paddock home, cloned in, since a macOS
  build needs a password.
- It runs in a paddock home of its own, a temporary folder with your paddock home's cache linked
  in, so your images and a `serve` you run are left alone. macOS's limit of two macOS VMs at
  once still counts both.
- The desktop builds download their packages each time: about 100 MB for Xfce, and 1 to 1.5 GB
  for GNOME. A run of all four templates and a macOS image took about 10 minutes on a Mac Studio.
- It prints a table for a pull request: each image's build, boot and restore times, the OS it
  reports, the screen's size and the app whose tree it read. It keeps each image's logs and
  screenshots in the folder it names, and exits with 1 if any image failed.
