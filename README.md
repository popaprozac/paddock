# paddock

Fresh macOS VMs on demand, for AI agents, CI and remote development on Apple silicon.

paddock keeps warm macOS VMs ready on your Macs and hands one out in under a millisecond. Run
commands and git tasks in it, read its screen, click and type in it, then hand it back: it's wiped,
and a fresh one is ready about 6 s later. Agents get all of that over MCP. paddock drives Apple's
Virtualization.framework directly, with no Tart or Lume underneath, and it's open source under
Apache 2.0.

- **Golden images from a YAML file**, built with no one at the keyboard, for macOS 15, 26 and 27.
- **Warm clones.** APFS copy-on-write clones, restored from a saved state, one per slot.
- **Commands and git tasks** in the guest, through an agent that listens only on vsock.
- **A network per VM** that reaches only the host names you allow.
- **Screen and input from the host:** screenshots, the accessibility tree, mouse and keyboard;
  `paddock show` to take a VM over by hand while agents wait, and `paddock view` to do the same
  from any Mac, through the control plane.
- **A live view**, `paddock top`, of each Mac's CPU, memory and disk, and what each VM uses.
- **An MCP server**, `paddock mcp`, so an agent can drive a VM.
- **A pool of Macs.** A control plane hands out VMs from every Mac in it; the Macs only connect
  out, so none needs an open port.

## Requirements

- An Apple silicon Mac with macOS 14 or later. Building golden images with `paddock build` needs
  macOS 27 on the Mac.
- Swift 6, from Xcode or the Command Line Tools, and Go.
- About 50 GB free: the macOS restore image (about 26 GB, which you can delete afterward) and the
  golden image (about 25 GB).

## Quick start

**1. Build paddock.**

```bash
scripts/build.sh
export PATH="$PWD/.build/out/Products/Release:$PATH"
```

**2. Make a golden image**, the VM every clone starts from.

```bash
paddock init golden.yaml     # writes a commented image file to start from
paddock build golden.yaml    # installs macOS and sets it up; asks for the VM account's password
```

If you accept Apple's [macOS license](https://www.apple.com/legal/sla/), uncomment
`license: accept` in the file first, and the image needs nothing from you. Otherwise `build` tells
you what's left to click. To set an image up by hand instead, see
[Golden images](docs/golden-images.md).

**3. Serve it, and use a VM.**

```bash
paddock serve golden         # keeps a warm VM ready in each of two slots; leave it running
```

In another terminal:

```bash
paddock acquire                      # prints the VM's name, such as golden-slot1-5e2dc9-844a19
paddock exec <vm> -- sw_vers
paddock screenshot <vm>
paddock release <vm>                 # wipes it; a fresh one is ready in about 6 s
paddock top                          # watch the Mac and each VM, live; Ctrl-C quits
```

`paddock task` runs a command on a git branch in the VM and brings back what it commits; it needs
the Command Line Tools in the golden image, for `git`. `paddock init golden.yaml --template ci`
writes an image file that installs them; the default template has the same steps commented out.
See [Golden images](docs/golden-images.md#build-one-from-an-image-file).

**4. Give it to an agent.** In Claude Code, for example:

```bash
claude mcp add paddock -- "$PWD/.build/out/Products/Release/paddock" mcp
```

**5. Pool several Macs** (optional). Run the control plane on one Mac or a small server, then join
each Mac to it and log in from each person's Mac:

```bash
paddock-control run                                                      # on the control plane
paddock-control join-token                                               # there, for each Mac
paddock serve golden --control https://studio.local:7443 --join <token>  # on that Mac
paddock-control login-token                                              # there, for each person
paddock login https://studio.local:7443 --token <token>                  # on their Mac
```

From then on, `acquire` and the commands after it use the whole pool, and `paddock top` shows
every Mac in it. See
[A pool of Macs](docs/control-plane.md).

## Documentation

| Doc | What's in it |
| --- | --- |
| [Golden images](docs/golden-images.md) | Image files, how `build` sets up each macOS version, setting up by hand, `grant`, what an image allows, MDM |
| [Commands](docs/commands.md) | Every command and its flags, what `paddock top` shows, where paddock keeps its files, running a task over SSH, what `bench` measures |
| [Agents, screenshots and input](docs/agents.md) | `paddock mcp` and its tools, how screenshots and input work |
| [Setting up Macs](docs/hosts.md) | What `serve` needs from a Mac, running it at login, and how each kind of host comes back after a restart, FileVault and EC2 Mac included |
| [A pool of Macs](docs/control-plane.md) | The control plane: setup, commands, placement, where it can run, how it keeps the pool safe |
| [The userspace network](docs/network.md) | A network per VM that reaches only the names its session allows |
| [The guest agent](docs/guest-agent.md) | `paddock-guestd` and `paddock-session`: their protocols, and how they answer only the host |
| [Building and testing](docs/development.md) | The build script, signing, the Go modules, running the tests |
| [Limits](docs/limits.md) | macOS's limits on VMs, and paddock's own |

## License

Apache 2.0. See [LICENSE](LICENSE).
