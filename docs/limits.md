# Limits

- macOS allows at most two macOS VMs running at once on one host. Linux and Windows VMs don't
  count toward that: `serve` keeps at most two slots of a macOS image, and any number of a Linux
  or Windows image, as memory allows.
- A VM costs its Mac more memory than it's configured with: an 8 GB VM's process took 10.7
  to 13.6 GB once warm in testing, as `paddock top` shows. `serve` counts each VM at 1.7 times its
  memory, measured only for 8 GB VMs, when it warns at startup, and warns again while it runs if
  macOS's memory pressure rises. On a 36 GB Mac, two 8 GB slots brought pressure to warn.
- A restored Linux VM costs its Mac all of its memory at once, plus a little: a 4 GB Debian 13
  VM took 4.2 GB as soon as it restored, and an Ubuntu 26.04 one 4.6 GB. A desktop costs more
  once it's used: after opening an app and reading its tree, Debian's Xfce took 4.5 GB and
  Ubuntu's GNOME 6.3 GB. One that booted instead, as `serve`'s slots do while the screen is
  locked, took 0.45 GB idle, or 0.82 GB with Xfce, and keeps whatever it uses until it stops.
  `serve` counts a Linux VM at 1.15 times its memory, or 1.6 times with a desktop. It counts a
  Windows VM at 1.6 times too, which hasn't been measured on Windows.
- A slot's saved state doesn't restore while the Mac's screen is locked, so `serve` boots fresh
  clones instead, which takes longer (see [What serve needs](hosts.md#what-serve-needs)).
- Clones must be on the same APFS volume as their source. Cloning fails rather than copying.
- Networking is macOS's shared NAT, or with `--userspace` a network of each VM's own, where a
  VM reaches only the names its `acquire --allow` listed (see
  [The userspace network](network.md)). It moves about 0.35 GB/s against about
  4 GB/s for NAT, measured downloading from the host.
- On the NAT network, a restored guest's traffic starts flowing 1 to 3 s after the guest
  reports its address and DNS server, so the first network request in a freshly handed-out VM
  can stall that long: the first DNS lookup took 0.8 to 2.0 s in testing, later ones about
  1 ms. Nothing the guest reports shows when its packets start getting through, so `serve`
  can't wait for it. The userspace network doesn't have the delay.
- Every clone has a new MAC address, so every boot takes a new lease from macOS's DHCP server,
  which keeps leases for a day. The NAT network has about 250 addresses, so a few hundred clone
  boots in one day exhaust it and new guests get no address. Shorten the lease time if you
  benchmark heavily:

  ```bash
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600
  ```
- Each of `serve`'s slots has one identity, so every VM a slot hands out has the same MAC address
  and IP address. Each starts with its clock behind by the time since `serve` saved
  the slot's state, until macOS corrects it once the guest's network is back: from Apple's time
  servers on NAT, and from paddock-net on the userspace network.
- A VM whose holder went away without releasing it, as when a CI job is killed between
  `paddock acquire` and `paddock release`, or `paddock mcp` gets SIGKILL, stays handed out until
  nothing has used it for its idle time: an hour, unless `acquire --idle` asked for another.
  `paddock top` shows which VMs are held and by whom, and `paddock release --local <vm>` on the
  VM's Mac frees one sooner. A holder that only waits, with nothing to send its VM, keeps it with
  `paddock renew`.
- Clones always have macOS's screen lock on, whatever the golden image says: macOS keeps that
  setting with the machine's identity, which every clone changes, and turning it off takes the
  user's password. With no screen saver and no sleep nothing sets it off, but anything that
  starts the screen saver or locks the screen, such as Ctrl-Cmd-Q, locks the session until the
  password is typed. Release the VM to get a fresh one.
- `serve` needs a login session: its slots restore VMs from saved state, which macOS encrypts
  with a key in the user's keychain, and screenshots and input need the window server. It can't
  run as a LaunchDaemon, and after a restart nothing runs until someone logs in, so a Mac with
  FileVault, which turns off automatic login, needs a person after every restart (see
  [Setting up Macs](hosts.md)).
- Apple's macOS license permits macOS VMs for development and testing.
- A Linux VM has a display, keyboard and pointer only when its image has a desktop on a kernel
  that drives them (see [Desktop Linux](golden-images.md#desktop-linux)). Debian's genericcloud
  kernel has no graphics, USB controller or HID driver, and with USB devices attached its saved
  state doesn't restore, so a VM of such an image has none, and screenshots, input, `show` and
  `view` don't work with it.
- `axtree` reads a Linux desktop's tree through AT-SPI, tested with GTK apps under X11 and GTK 4
  apps under GNOME's Wayland. Under Wayland its frames have sizes but no screen positions: every
  one starts at 0, 0. Apps that publish only when accessibility is turned on, as Qt, Firefox and
  Chromium do, haven't been tested.
- Linux images come only from Debian's genericcloud and generic arm64 builds, Ubuntu's arm64
  server cloud image, or disks in the same formats (see [Linux images](golden-images.md#linux-images)).
  A Debian 13 golden image takes about 2.8 GB of disk, since Debian's tarball holds its disk's
  zeros and extracting writes them out, and an Ubuntu 26.04 one about 2.6 GB.
- A Windows VM's display is a fixed 1024x768. virtio-win's signed display driver, viogpudo,
  garbles the screen on Virtualization.framework at any mode change, so Windows must never change
  it: a resolution change inside a Windows VM breaks its screen until the VM is released, and in
  a golden image, for good. virtio-win has fixes under review
  ([#1687](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/1687),
  [#1717](https://github.com/virtio-win/kvm-guest-drivers-windows/pull/1717)); until a signed
  release has one, a larger display needs viogpudo built from source and Windows' test signing.
  `run`, `show` and `view` scale a Windows VM's screen rather than resize it.
- A Windows VM needs two private settings of Virtualization.framework, performance monitoring unit
  emulation and fine-grained traps, without which Windows Boot Manager hangs. A macOS release
  could drop or change them; paddock then refuses to start a Windows VM.
- Microsoft's [support page](https://support.microsoft.com/en-us/windows/experience/platform-variants/options-for-using-windows-11-with-mac-computers-with-apple-m1-m2-and-m3-chips)
  names Parallels Desktop as the authorized way to run Windows 11 Pro and Enterprise for Arm in a
  VM on Apple silicon Macs, and Windows 365 as the other way to use Windows on one. Whether your
  license covers running it in paddock is yours to check.
- A restart inside Windows stops the VM, since Virtualization.framework ends it, so Windows
  updates that restart need the VM started again.
- A Windows VM's agent reports the desktop up once the account's session runs Explorer, without
  checking that it's unlocked, so a Windows image must sign in by itself and never lock. A key
  sent about a second after a restored Windows VM was handed out was lost once in testing.
- A Windows VM keeps its image's time zone, which isn't synced from the Mac.
- Not tested with Windows: the userspace network, `run --share`, which needs WinFsp and
  virtio-win's virtiofs service in the guest, and horizontal scrolling.
- `paddock cp` and the MCP copy tools copy files, not folders. Through the pool a file is at most
  1 GB, and the Mac it's copied to holds a file coming out of a VM in memory until all of it is
  there.
