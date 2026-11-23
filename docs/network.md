# The userspace network

With `--userspace`, each VM's network is its own `paddock-net` process instead of macOS's shared
NAT. It gives the guest 192.168.127.2 by DHCP, on a lease that never expires, with the gateway
192.168.127.1 as its router and DNS server, and lets the guest reach only the names on its list.
A warm VM's list is empty.
`paddock acquire --allow github.com,*.githubusercontent.com` puts its list in force before
`serve` hands the VM out, through `net.sock`, a control socket paddock-net creates in the VM's
bundle that only you can open; a VM acquired without `--allow` reaches nothing. Releasing the VM
deletes it with its network. `bench --userspace` passes no list.

| What the guest sends | What paddock-net does |
| --- | --- |
| DNS to the gateway | A name on the list gets its IPv4 addresses from the host's resolver and no other records. Any other name has no such name (NXDOMAIN), with an SOA record that says not to cache the answer. No query is passed on to another server. |
| TCP to port 443 | Reads the server name from the TLS ClientHello. If it is on the list, connects to that name from the host and passes the connection through; the address the guest connected to is ignored. Otherwise closes it. |
| TCP to port 80 | The same, with the HTTP request's `Host` header. |
| TCP to any other port | Resets it. |
| NTP to the gateway | Answers with the host's time. `time.apple.com` resolves to the gateway whatever the list says, so macOS sets the guest's clock from it. |
| Anything else | Drops it: UDP other than DNS, NTP and DHCP to the gateway, so DNS sent to any other server too, and ICMP. |

An entry `example.com` matches that name only; `*.example.com` matches every name under it, but
not `example.com` itself. Matching ignores the case of ASCII letters and a trailing dot. The guest
reaches a name only if it's spelled as a host name, in letters, digits, hyphens and dots: a TLS
server name or `Host` with any other character, such as `gİthub.com`, is refused, and logged in
quotes. Connections from the host never go to a loopback or link-local address,
whatever a name resolves to, so the host's own services and EC2's instance metadata stay out of
reach. Nothing on the host's networks can open a connection to the guest. Each decision is one
line on paddock-net's stderr, which is `serve`'s or `bench`'s, such as `now allowing github.com`,
`allow github.com:443`, `deny example.com:443: not on the list`, `deny "gİthub.com":443: not a
host name` and `deny dns example.com: not on the list`.

paddock-net doesn't decrypt TLS, so a client can name an allowed host in its ClientHello and then
ask that server for another site it also serves. Only ports 80 and 443 work, so git needs HTTPS
rather than SSH. HTTP/3 runs over UDP and is dropped; clients fall back to TCP.

A macOS guest's clock starts where golden's last shutdown left it, 3.6 hours behind in testing,
and a restored guest's where its state was saved. macOS sets it from paddock-net's NTP about
0.1 s after the guest's network comes back, so a VM `serve` hands out has the right time: 73 µs
off in testing. The lease never expires because of that jump: the slot's guest leases its
address before its clock moves forward, and an expired lease would make every restore go through
DHCP from the start, 1.6 s slower than reusing it.

A restored guest asks for about 20 Apple names and is refused. macOS keeps a denied name for
about 75 s whatever the answer says, so a name the warm guest looked up shortly before Assign,
such as one of those Apple names, can stay unresolvable for that long after its acquire allowed
it.
