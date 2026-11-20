# A pool of Macs: the control plane

`paddock-control` is the one place that knows every Mac in a pool. Each Mac's `paddock serve`
links out to it and reports its slots, and every 2 s what it and its VMs use; nothing connects in to
a Mac, so a Mac needs no open port.
People's CLIs and agents log in to it, and from then on `acquire` takes a warm VM from whichever
Mac has one, and the commands that take a VM reach it through the control plane.

```bash
paddock-control run                         # on the Mac or server that runs it
paddock-control join-token                  # there: a one-use token for the next Mac
paddock serve golden --control https://studio.local:7443 --join <token>   # on that Mac, once
paddock serve golden --control https://studio.local:7443                  # on that Mac, after
paddock-control login-token                 # back where it runs: a one-use token for a person
paddock login https://studio.local:7443 --token <token>                   # on their Mac
paddock hosts                               # there: every Mac and its slots
paddock top                                 # there: every Mac and VM, live
paddock acquire                             # a warm VM from any Mac in the pool
```

## Commands

| Command | What it does |
| --- | --- |
| `paddock-control run [-listen addr] [-name name] [-state folder]` | Runs the control plane on HTTPS, port 7443 on every address by default, and prints the URLs hosts can use. `-listen` picks one address and port; `-name` adds a name or address the machine is reached by that it can't find itself, such as a MagicDNS name or a load balancer's, and repeats. |
| `paddock-control join-token [-ttl 1h]` | Makes a token one Mac can join with, for an hour by default and 24 hours at most, and prints the `serve` command to run on that Mac. |
| `paddock-control hosts [-json]` | Lists every Mac that joined: online or not, its image, its slots (warm, assigned, preparing or empty), macOS and paddock versions; with `-json`, also its address, cores, memory and free disk, what it and each VM use now, and the client holding each VM. |
| `paddock-control remove-host <ID or name>` | Removes a Mac: its link closes at once, and it can't link again unless it joins with a new token. |
| `paddock-control login-token [-ttl 1h]` | Makes a token one person's CLI or one agent can log in with, for an hour by default and 24 hours at most, and prints the `paddock login` command to run. |
| `paddock-control clients [-json]` | Lists every CLI or agent that logged in: its open links, when it was last seen and when it logged in. |
| `paddock-control remove-client <ID or name>` | Removes a client: its links close at once, the VMs it holds are released, and it can't connect again unless it logs in with a new token. |
| `paddock login <url> --token <token>` | On a person's Mac: logs in to the control plane, so this Mac's VM commands use the pool. Logging in again replaces the login. |
| `paddock logout` | The control plane forgets this client and releases its VMs, and this Mac forgets the login. |
| `paddock hosts [--json]` | Lists the pool's Macs, as `paddock-control hosts` does, from any logged-in Mac. |
| `paddock top [--json]` | Shows every Mac in the pool and each slot's VM, who holds it and what it uses, redrawn every 2 s (see [paddock top](commands.md#watching-with-paddock-top)). |

The admin commands reach the running control plane over a Unix socket in its state folder, so
they run on the machine it runs on, as its user. On a Mac, `--control` on `serve` takes any URL
for the same control plane once it has joined: it trusts the control plane's CA, not one name, so
a laptop can use the LAN name at home and the MagicDNS name away.

## How acquire picks a Mac

Logged in, `acquire` picks the online Mac serving the image with the most free warm slots; with
none free, it waits its turn, first come first served, and says so. `--image` names the golden
image when the pool serves more than one. `exec`, `task`, `screenshot`, `axtree`, the input
commands, `view`, `release` and `paddock mcp` then reach that VM through the control plane,
whichever Mac it runs on. Screenshots and task bundles travel in pieces of 256 KB; a bundle can be
up to 1 GB. If a client leaves before its bundle is all up, or sends more than 1 GB, the control
plane tells the Mac to drop what it has so far. A view runs both ways for as long as its window is
open: frames come down in lines of up to 192 KB of video, and the viewer's acknowledgments and input
go up as they happen. If the viewer's link closes, the control plane tells the Mac to end the view.
A Mac can serve the pool and be logged in to it at once: its host link and its login are kept
apart.

## Where it can run

| Setup | Control plane | URL the Macs use |
| --- | --- | --- |
| Your Macs on one network | one of them | `https://<mac>.local:7443`, found by itself |
| Your Macs anywhere, on Tailscale | one of them | its MagicDNS name, added with `-name`; tailnet addresses are found by themselves |
| A small server on your tailnet | a Linux machine, `GOOS=linux go build` in `paddock-control/` | its MagicDNS name, with `-listen` on its tailnet address so it answers nowhere else |
| A VPC | a Linux service in a private subnet | a private DNS name, with a security group open only to the Macs |

## How it keeps the pool safe

- **Encrypted, to one CA.** TLS 1.3 only. On first run the control plane makes its own CA in its
  state folder; the server certificate is remade every hour, signed by that CA, for this
  machine's names and addresses and every `-name`, so a new DHCP or Tailscale address doesn't
  break anything. A join or login token carries the SHA-256 of the CA's public key: a joining Mac
  or a logging-in client trusts that CA and no other, and only for the host in its URL. A
  certificate that doesn't check out stops the link, with the `-name` to add if the control plane
  didn't know that name.
- **A key per Mac and per client, which never leaves it.** When it joins, `serve` makes a P-256
  key with CryptoKit and sends only the public half. The private key stays in
  `$PADDOCK_HOME/host/host.key` (0600, in a 0700 folder). Every link starts with the control
  plane's 32 random bytes, which the Mac signs with that key after the text `paddock-link-v1:`;
  the control plane checks the signature against the key it enrolled. That is the proof a TLS
  client certificate gives, without putting the key in the Keychain. `paddock login` does the
  same with a key of its own in `$PADDOCK_HOME/client/client.key`, signing after
  `paddock-client-v1:`, so a Mac's key can't act as a client, or a client's as a Mac.
- **Tokens.** One use, an hour by default, kept only as a SHA-256, never logged. A join token adds
  a Mac and a login token a client; neither works as the other. After 10 failed enrollments in a
  minute, enrollment stops for the rest of that minute. Until it's used, anyone with a token can
  add a Mac or log in, so pass it only to the Mac or person you add.
- **Nothing without identity.** A caller the control plane doesn't know can reach only enrollment,
  which needs a valid token. Everything else takes an enrolled Mac's or client's signature, or the
  admin socket, which only the control plane's user can open.
- **The VMs, never the Mac.** Down a Mac's link the control plane sends only `serve`'s VM requests
  (acquire, release, exec, axtree, input, screenshot and task), which `serve` checks as it checks
  its own socket's: only VMs it handed out. The Mac refuses a request that names a file, and picks
  its own temporary files for screenshots and bundles.
- **A VM is its acquirer's.** The control plane keeps which client holds each VM, in its state, so
  a restart keeps it. Only that client can use or release the VM; anyone else's request for it is
  refused. A hand-out ends when its client releases the VM or is removed or logs out, or when the
  VM's Mac reports its slots without it, as after its `serve` stops or restarts.
- **Removal is immediate.** `remove-host` deletes the Mac's key and closes its link; its next link
  is refused. `remove-client` and `paddock logout` do the same for a client, and release its VMs.
- **State.** Everything is in `~/.paddock/control`, or `-state`, which only the control plane's user
  can read: `ca.key` and `ca.crt`; `state.json`, with each Mac's and client's public key, the
  hashes of unused tokens and which client holds each VM, until the VM's Mac stops reporting it;
  `audit.log`, a JSON line for each token made, Mac or client enrolled, refused or removed, link
  opened, refused or closed, VM handed out or released, and request, with its client, VM and
  operation, with no secrets in it; and `admin.sock`.
- **Everyone logged in sees the pool.** Every client sees every Mac, its slots, what each Mac and
  VM uses, and which client holds each VM, in `paddock hosts` and `paddock top`. The numbers are
  measured on each Mac, never asked of a guest.
- **Your network decides who can reach it.** Run it on the LAN, Tailscale, a VPN or a private
  subnet; don't forward its port to the internet. `-listen` keeps it to one address.

## When the control plane is down

The link never holds up a Mac: while the control plane is down or restarting, `serve` hands out
VMs as before, says once that the link is down, and links again by itself, waiting 1 s, then
twice as long each time up to 30 s. The control plane closes links politely when it stops, so a
Mac can tell that it went away from a dropped network. A restart ends the requests passing
through it, such as a running `exec`; the VMs, and who holds them, carry on. Requests to one Mac
share its link, so a client that reads its answers slowly holds up that Mac's other requests until
it catches up. There is one control plane, keeping its state in one file, so it can't run as
several copies for failover.
