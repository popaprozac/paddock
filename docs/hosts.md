# Setting up Macs for paddock

For whoever sets up the Macs that run `paddock serve`: a Mac at someone's desk, a Mac in a rack,
or a cloud Mac. It covers what `serve` needs from the Mac, how to keep it running, and how each
kind of host comes back after a restart.

## What serve needs

- An Apple silicon Mac with macOS 14 or later (see [Requirements](../README.md#requirements)).
  macOS runs at most two macOS VMs at once on one Mac, and a macOS VM costs its Mac about 1.7
  times its own memory, a Linux VM about 1.15 times, or 1.6 times with a desktop, and a
  Windows VM is counted at 1.6 times, not yet measured (see [Limits](limits.md)).
- **A login session.** `serve` must run as a user who is logged in at the Mac's screen, whether in
  person, through Screen Sharing, or by automatic login. Two things need one:
  - Keeping slots warm. Each slot restores its VM from saved state, and macOS encrypts saved state
    with a key it keeps in the user's keychain, which only a login session can reach, and only
    while the screen is unlocked.
  - Screenshots, input, `paddock show` and `paddock view`, which need the window server.
- So `serve` doesn't run as a LaunchDaemon. A daemon starts before anyone logs in, but its slots
  can't save state: in testing on macOS 27, Apple's VM service crashed ("Failed to talk to secd")
  whenever the keychain didn't answer. That was every time before login, and sometimes with the user
  logged in. A daemon gets no screens either.
- No open port. `serve` links out to the control plane, and nothing connects in to the Mac.
- **The screen unlocked, for fast refills.** While the Mac's screen is locked, every restore fails
  with "permission denied", so each slot boots a fresh clone of the source instead: about 3 s for
  a Debian VM, which restores in 0.6 s, and about 33 s for macOS (tested on macOS 27).
  Saving state still works, and restores work again once the screen is unlocked. Screenshots and
  input keep working while it's locked. On a Mac that only runs paddock, set System Settings ›
  Lock Screen never to require a password after the screen saver starts or the display turns off.
- The display can sleep. `serve` keeps the Mac from idle sleep while it runs, so a sleep timer
  doesn't stop its slots. Closing a laptop's lid or choosing Sleep still puts it to sleep.

## Running serve at login

A LaunchAgent starts `serve` each time its user logs in and starts it again if it fails. At logout,
restart or shutdown, launchd stops it, and `serve` deletes its slots' VMs as it does on Ctrl-C.

1. If the Mac joins a control plane, join once by hand, since a join token works only once. Run
   `serve` with `--join`, wait for `Linked to the control plane`, then press Ctrl-C:

   ```bash
   paddock serve golden --control https://control.example:7443 --join <token>
   ```

   `serve` keeps the identity in the paddock home and links with it from then on.
2. Save this as `~/Library/LaunchAgents/dev.paddock.serve.plist`. Use the path paddock is at and
   the user's home folder: launchd doesn't expand `~`. Leave out the two `--control` lines on a
   Mac that serves only itself.

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key>
       <string>dev.paddock.serve</string>
       <key>ProgramArguments</key>
       <array>
           <string>/usr/local/bin/paddock</string>
           <string>serve</string>
           <string>golden</string>
           <string>--control</string>
           <string>https://control.example:7443</string>
       </array>
       <key>LimitLoadToSessionType</key>
       <string>Aqua</string>
       <key>RunAtLoad</key>
       <true/>
       <key>KeepAlive</key>
       <dict>
           <key>SuccessfulExit</key>
           <false/>
       </dict>
       <key>StandardOutPath</key>
       <string>/Users/paddock/Library/Logs/paddock-serve.log</string>
       <key>StandardErrorPath</key>
       <string>/Users/paddock/Library/Logs/paddock-serve.log</string>
   </dict>
   </plist>
   ```

   - `LimitLoadToSessionType` `Aqua` loads it only in a login session.
   - `KeepAlive` starts `serve` again if it exits with an error or is killed. The new `serve`
     deletes the VMs the old one left. A `serve` that stopped cleanly stays stopped.
3. Load it now. From the next login on, launchd loads it by itself:

   ```bash
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.paddock.serve.plist
   ```

4. Follow it in its log, and check it with `paddock top --local`:

   ```bash
   tail -f ~/Library/Logs/paddock-serve.log
   ```

To stop it, unload it. `launchctl` returns at once, and `serve` deletes its slots' VMs within a few
seconds:

```bash
launchctl bootout gui/$(id -u)/dev.paddock.serve
```

macOS lists the agent in System Settings › General › Login Items & Extensions, where the user can
turn it off. An MDM can manage that list.

## Kinds of host

| Host | FileVault | After a restart | serve |
| --- | --- | --- | --- |
| [A Mac at someone's desk](#a-mac-at-someones-desk) | on | its user logs in | starts at that login |
| [A dedicated Mac, FileVault off](#a-dedicated-mac-filevault-off) | off | it logs itself in | starts by itself |
| [A dedicated Mac with FileVault](#a-dedicated-mac-with-filevault) | on | a person logs in | starts at that login |
| [Amazon EC2 Mac](#amazon-ec2-mac) | off, as AWS requires | it logs itself in | starts by itself |

### A Mac at someone's desk

`serve` runs while its user is logged in, from a Terminal or as the LaunchAgent above. FileVault
can stay on: after a restart, the user's password at the FileVault screen logs them in, and the
LaunchAgent starts `serve`.

- **Memory:** the VMs share the Mac with its user's own work. Two 8 GB VMs take about 27 GB, so a
  Mac someone works on often fits one slot, `--slots 1`, or smaller VMs.
- **Screen lock:** while its user is away and the screen is locked, each refill boots a fresh
  clone rather than restoring one (see [What serve needs](#what-serve-needs)).
- **Laptops:** closing the lid puts the Mac to sleep, VMs and all. `serve` only stops idle sleep,
  and keeps a laptop on battery awake while it runs.
- **In a pool:** a Mac that serves the pool takes requests from anyone in it, wherever the Mac
  is. To keep a laptop's VMs to its own user away from its desk, run `serve` there without
  `--control`. Its user can still take the laptop's VMs with `acquire --local` and the pool's
  with `acquire`.

### A dedicated Mac, FileVault off

This is for a Mac in a place you trust, such as a locked room on a trusted network. Give paddock an
account of its own, turn on automatic login for it, and run `serve` as its LaunchAgent. After any
restart, planned or not, the Mac logs itself in, `serve` starts and fills its slots, and it links
to the control plane again by itself.

- Turn on automatic login in System Settings › Users & Groups, or from a shell. Without
  `-password` it asks for the password, which keeps it out of the shell's history:

  ```bash
  sudo sysadminctl -autologin set -userName paddock
  ```

- Automatic login keeps the account's password in `/etc/kcpassword`, obfuscated but reversible,
  so anyone with root on the Mac or a copy of its disk can recover it. Give each Mac its own
  password, kept in your secrets manager, so one Mac's file opens no other Mac.
- macOS doesn't allow automatic login with FileVault on.

### A dedicated Mac with FileVault

This is for when FileVault is required. Every restart needs a person to log in before `serve` runs.

- **Planned restarts**, such as macOS updates: `sudo fdesetup authrestart` restarts past the
  FileVault screen once. On macOS 27 the Mac then stops at the login window, not logged in, so
  someone still logs in, in person or through Screen Sharing, before `serve` starts.
- **Crashes and other restarts** stop at the FileVault screen. A FileVault user's password there
  unlocks the disk and logs that user in.
- **Unlocking from elsewhere:** on Apple silicon with macOS 26 or later, with Remote Login on, a
  FileVault user's password over SSH unlocks the disk after a restart (see Apple's
  [Platform Security guide](https://support.apple.com/guide/security/sec8447f5049/web)). Turning
  on Remote Login also turns on ordinary SSH. paddock hasn't been tested with this, including
  whether the Mac then needs a login through Screen Sharing before `serve` starts.

The slots are empty from the restart until that login. VMs that were handed out when the Mac went
down are gone either way.

### Amazon EC2 Mac

EC2 Mac instances are Mac hardware on a Dedicated Host, one instance per host, which AWS bills
for at least 24 hours once allocated, as Apple's license requires. They suit the setup for
[a dedicated Mac with FileVault off](#a-dedicated-mac-filevault-off), with `ec2-user` as the account:

- **FileVault:** keep it off. AWS warns that an EC2 Mac with FileVault on fails to boot. Use EBS
  encryption for its volumes instead.
- **The account:** you reach a new instance by SSH as `ec2-user`, with the instance's key pair. It
  has no password, but automatic login, Screen Sharing and macOS updates need one. Set one, its
  own for each Mac:

  ```bash
  sudo passwd ec2-user
  ```

  Then turn on automatic login for `ec2-user` as above. For a person to see the screen, AWS's
  guide turns on Screen Sharing and reaches it through an SSH or Session Manager tunnel to port
  5900, so the instance opens no port.
- **Disk:** keep the paddock home on the instance's EBS boot volume, since clones must be on the
  same APFS volume as the golden image. AWS recommends against the Mac's internal SSD and suggests
  volumes with 10,000 IOPS and 400 MiB/s. Restoring a slot reads about 2.7 GB of saved state, so
  the volume's speed sets how long a release takes to refill.
- **Memory:** two 8 GB VMs need about 27 GB on top of what macOS itself uses. On an instance type
  with less memory, use `--slots 1` or a smaller VM.
- **macOS updates** are yours to schedule, not AWS's. On Apple silicon, AWS's update guide needs
  `ec2-user`'s password and secure token. After the restart, automatic login brings `serve` back.
- **Golden images:** paddock has no command to copy a golden image from one Mac to another, so
  each Mac builds its own with `paddock build`.
