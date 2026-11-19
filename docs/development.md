# Building and testing

## Requirements

- An Apple silicon Mac running macOS 14 or later.
- Swift 6 from Xcode or the Command Line Tools.
- Go, for `paddock-net`. Its dependencies need Go 1.26; with an older Go installed, Go fetches
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
