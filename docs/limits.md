# Limits

- macOS allows at most two macOS VMs running at once on one host. Linux VMs don't count toward
  that: `serve` keeps at most two slots of a macOS image, and any number of a Linux image, as
  memory allows.
- A VM costs its Mac more memory than it's configured with: an 8 GB VM's process took 10.7
  to 13.6 GB once warm in testing, as `paddock top` shows. `serve` counts each VM at 1.7 times its
  memory, measured only for 8 GB VMs, when it warns at startup, and warns again while it runs if
  macOS's memory pressure rises. On a 36 GB Mac, two 8 GB slots brought pressure to warn.
- A restored Linux VM costs its Mac all of its memory at once, plus a little: a 4 GB Debian 13
  VM took 4.21 GB as soon as it restored, with a desktop or without. One that booted instead, as
  `serve`'s slots do while the screen is locked, took 0.45 GB idle, or 0.82 GB with a desktop,
  and keeps whatever it uses until it stops. `serve` counts a Linux VM at 1.05 times its memory.
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
- `axtree` reads a Linux desktop's tree through AT-SPI, tested with GTK apps under X11. Apps
  that publish only when accessibility is turned on, as Qt, Firefox and Chromium do, and Wayland
  desktops, where AT-SPI gives no screen positions, haven't been tested.
- Linux images come only from Debian's genericcloud and generic arm64 builds, or disks in the same format
  (see [Linux images](golden-images.md#linux-images)). A Debian 13 golden image takes about 2.8 GB
  of disk, since Debian's tarball holds its disk's zeros and extracting writes them out.
