# Limits

- macOS allows at most two macOS VMs running at once on one host.
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
- Apple's macOS license permits macOS VMs for development and testing.
