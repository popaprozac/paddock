// paddock-control is paddock's control plane: the one place that knows every Mac in a pool.
//
// Each Mac's `paddock serve` connects out to it over HTTPS and keeps one WebSocket open, so no
// Mac needs an open port. A Mac joins once with a join token, which carries the SHA-256 of the
// control plane's own CA: the Mac trusts that CA and nothing else, and sends a P-256 public key it
// just made. Every link then starts with the control plane sending 32 random bytes for the Mac to
// sign with that key. The CA, the state and the audit log stay in the state folder, readable only
// by the user the control plane runs as, and admin commands reach it over a Unix socket there.
package main

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/coder/websocket"
)

const usage = `usage: paddock-control <command> [flags]

commands:
  run           start the control plane
  join-token    make a one-use token for a Mac to join the pool with
  login-token   make a one-use token for a person's CLI or an agent to log in with
  hosts         list the Macs that joined, and what each reports
  clients       list the CLIs and agents that logged in
  remove-host   remove a Mac: its link closes and it can't connect again
  remove-client remove a CLI or agent: its links close and it can't connect again

Run 'paddock-control <command> -h' for its flags.
`

func main() {
	log.SetFlags(log.Ldate | log.Ltime)
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "run":
		err = run(os.Args[2:])
	case "join-token":
		err = joinToken(os.Args[2:])
	case "hosts":
		err = hosts(os.Args[2:])
	case "login-token":
		err = loginToken(os.Args[2:])
	case "clients":
		err = clients(os.Args[2:])
	case "remove-host":
		err = remove(hostKind, os.Args[2:])
	case "remove-client":
		err = remove(clientKind, os.Args[2:])
	case "-h", "-help", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// stateFlag adds -state to a command, defaulting to control/ in the paddock home.
func stateFlag(flags *flag.FlagSet) *string {
	home := os.Getenv("PADDOCK_HOME")
	if home == "" {
		if dir, err := os.UserHomeDir(); err == nil {
			home = filepath.Join(dir, ".paddock")
		}
	}
	return flags.String("state", filepath.Join(home, "control"), "folder for the control plane's CA, state and audit log")
}

// openStateDir makes the state folder if needed and keeps it to this user alone.
func openStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

func run(args []string) error {
	flags := flag.NewFlagSet("run", flag.ExitOnError)
	dir := stateFlag(flags)
	listen := flags.String("listen", ":7443", "address to listen on; give the LAN or tailnet address to listen only there")
	var names []string
	flags.Func("name", "another name or address hosts and clients use for this machine, such as its MagicDNS name (repeatable)", func(name string) error {
		names = append(names, name)
		return nil
	})
	flags.Parse(args)

	if err := openStateDir(*dir); err != nil {
		return err
	}
	authority, err := loadOrCreateAuthority(*dir)
	if err != nil {
		return err
	}
	st, err := openState(*dir)
	if err != nil {
		return err
	}
	audit, err := openAuditLog(filepath.Join(*dir, "audit.log"))
	if err != nil {
		return err
	}
	defer audit.close()
	srv := newServer(st, authority, audit)

	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	port := fmt.Sprint(listener.Addr().(*net.TCPAddr).Port)
	urls := func() []string { return reachableURLs(*listen, port, names) }
	admin, err := srv.listenAdmin(adminSocketPath(*dir), urls)
	if err != nil {
		listener.Close()
		return err
	}
	defer admin.Close()

	certs := &certificates{authority: authority, extra: names}
	httpServer := &http.Server{
		Handler: srv.routes(),
		TLSConfig: &tls.Config{
			MinVersion:     tls.VersionTLS13,
			GetCertificate: certs.get,
			// Links are WebSockets over HTTP/1.1; the library takes no HTTP/2.
			NextProtos: []string{"http/1.1"},
		},
		TLSNextProto:      map[string]func(*http.Server, *tls.Conn, http.Handler){},
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          log.New(os.Stderr, "", log.Ldate|log.Ltime),
	}

	fmt.Printf("paddock control plane listening on %s\n", listener.Addr())
	fmt.Printf("  hosts and clients can use: %s\n", strings.Join(urls(), ", "))
	fmt.Printf("  CA pin: sha256:%s\n", hex.EncodeToString(authority.pin()))
	fmt.Printf("  state: %s\n", *dir)
	fmt.Println("Add a Mac: paddock-control join-token")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- httpServer.ServeTLS(listener, "", "") }()
	select {
	case err := <-done:
		return err
	case <-stop:
		fmt.Println("\nStopping")
		srv.closeAll()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(ctx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

// reachableURLs is the URLs a host or client may use: the one address --listen names, or every
// name and address this machine has.
func reachableURLs(listen, port string, extra []string) []string {
	if host, _, err := net.SplitHostPort(listen); err == nil && host != "" && host != "0.0.0.0" && host != "::" {
		return []string{"https://" + net.JoinHostPort(host, port)}
	}
	return urlsFor(currentReach(extra), port)
}

// urlsFor is the URLs worth showing for r: its names, then its IPv4 addresses. IPv6 addresses are
// only shown when there's nothing else, since a Mac has several that change by the day; the
// certificate covers them all either way.
func urlsFor(r reach, port string) []string {
	var urls, ipv6 []string
	for _, name := range r.names {
		if name != "localhost" {
			urls = append(urls, "https://"+net.JoinHostPort(name, port))
		}
	}
	for _, ip := range r.addresses {
		switch {
		case ip.IsLoopback():
		case ip.To4() != nil:
			urls = append(urls, "https://"+net.JoinHostPort(ip.String(), port))
		default:
			ipv6 = append(ipv6, "https://"+net.JoinHostPort(ip.String(), port))
		}
	}
	if len(urls) == 0 {
		return ipv6
	}
	return urls
}

func joinToken(args []string) error {
	return token(hostKind, args)
}

func loginToken(args []string) error {
	return token(clientKind, args)
}

// token makes a one-use token of kind k and says what to do with it.
func token(k kind, args []string) error {
	op := map[kind]string{hostKind: "join-token", clientKind: "login-token"}[k]
	flags := flag.NewFlagSet(op, flag.ExitOnError)
	dir := stateFlag(flags)
	ttl := flags.Duration("ttl", defaultTokenTTL, "how long the token can be used, at most 24h")
	flags.Parse(args)
	response, err := askAdmin(*dir, adminRequest{Op: op, TTL: *ttl})
	if err != nil {
		return err
	}
	url := "https://<this machine>:7443"
	if len(response.URLs) > 0 {
		url = response.URLs[0]
	}
	until := response.Expires.Local().Format("Jan 2 15:04")
	if k == clientKind {
		fmt.Printf("Login token, for one person's CLI or one agent, until %s:\n\n  %s\n\n", until, response.Token)
		fmt.Println("Anyone with it can use the pool's VMs until then, so pass it on only to whoever logs in. There:")
		fmt.Printf("\n  paddock login %s --token <token>\n\n", url)
	} else {
		fmt.Printf("Join token, for one Mac, until %s:\n\n  %s\n\n", until, response.Token)
		fmt.Println("Anyone with it can add a Mac until then, so pass it on only to the Mac you add. On that Mac:")
		fmt.Printf("\n  paddock serve <golden image> --control %s --join <token>\n\n", url)
	}
	if len(response.URLs) > 1 {
		fmt.Printf("The control plane also answers at: %s\n", strings.Join(response.URLs[1:], ", "))
	}
	return nil
}

func hosts(args []string) error {
	flags := flag.NewFlagSet("hosts", flag.ExitOnError)
	dir := stateFlag(flags)
	asJSON := flags.Bool("json", false, "print JSON")
	flags.Parse(args)
	response, err := askAdmin(*dir, adminRequest{Op: "hosts"})
	if err != nil {
		return err
	}
	list := response.Hosts
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	if *asJSON {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(list)
	}
	if len(list) == 0 {
		fmt.Println("No Macs have joined yet. Add one: paddock-control join-token")
		return nil
	}
	table := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(table, "NAME\tID\tSTATUS\tIMAGE\tSLOTS\tMACOS\tPADDOCK")
	staleCount := 0
	for _, host := range list {
		status := "never linked"
		switch {
		case host.Online:
			status = "online since " + host.Connected.Local().Format("Jan 2 15:04")
		case !host.LastSeen.IsZero():
			status = "offline since " + host.LastSeen.Local().Format("Jan 2 15:04")
		}
		if host.Stale {
			status += " (stale)"
			staleCount++
		}
		fmt.Fprintf(table, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", host.Name, host.ID, status, dash(host.Image),
			slotSummary(host.Slots), dash(host.MacOS), dash(host.Version))
	}
	if err := table.Flush(); err != nil {
		return err
	}
	printStaleNote(staleCount, "Mac", "If a Mac is gone for good, remove it: paddock-control remove-host <ID>")
	return nil
}

// printStaleNote says how many entries a list marked stale and how to remove one; none, nothing.
func printStaleNote(count int, noun, remove string) {
	if count == 0 {
		return
	}
	plural := ""
	if count > 1 {
		plural = "s"
	}
	fmt.Printf("\n%d %s%s marked stale: never linked, or not for over %d days. %s\n", count, noun, plural, staleDays, remove)
}

func clients(args []string) error {
	flags := flag.NewFlagSet("clients", flag.ExitOnError)
	dir := stateFlag(flags)
	asJSON := flags.Bool("json", false, "print JSON")
	flags.Parse(args)
	response, err := askAdmin(*dir, adminRequest{Op: "clients"})
	if err != nil {
		return err
	}
	list := response.Clients
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	if *asJSON {
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(list)
	}
	if len(list) == 0 {
		fmt.Println("No one has logged in yet. Make a token for someone: paddock-control login-token")
		return nil
	}
	table := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(table, "NAME\tID\tLINKS\tLAST SEEN\tLOGGED IN")
	staleCount := 0
	for _, c := range list {
		seen := "never"
		if !c.LastSeen.IsZero() {
			seen = c.LastSeen.Local().Format("Jan 2 15:04")
		}
		if c.Stale {
			seen += " (stale)"
			staleCount++
		}
		fmt.Fprintf(table, "%s\t%s\t%d\t%s\t%s\n", c.Name, c.ID, c.Links, seen, c.Enrolled.Local().Format("Jan 2 15:04"))
	}
	if err := table.Flush(); err != nil {
		return err
	}
	printStaleNote(staleCount, "client", "If one is no longer used, remove it: paddock-control remove-client <ID>")
	return nil
}

// remove removes a host or a client by ID or name.
func remove(k kind, args []string) error {
	op := "remove-" + string(k)
	flags := flag.NewFlagSet(op, flag.ExitOnError)
	dir := stateFlag(flags)
	flags.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: paddock-control %s [-state folder] <%s ID or name>\n", op, k)
		flags.PrintDefaults()
	}
	flags.Parse(args)
	if flags.NArg() != 1 {
		flags.Usage()
		os.Exit(2)
	}
	response, err := askAdmin(*dir, adminRequest{Op: op, Host: flags.Arg(0)})
	if err != nil {
		return err
	}
	again := "joins with a new token"
	if k == clientKind {
		again = "logs in with a new token"
	}
	fmt.Printf("Removed %s: its links are closed, and it can't connect again unless it %s.\n", response.Removed, again)
	return nil
}

// slotSummary is a host's slots in a few words, such as "1 warm, 1 assigned".
func slotSummary(slots []slot) string {
	if len(slots) == 0 {
		return "-"
	}
	counts := map[string]int{}
	var order []string
	for _, s := range slots {
		if counts[s.State] == 0 {
			order = append(order, s.State)
		}
		counts[s.State]++
	}
	parts := make([]string, len(order))
	for i, state := range order {
		parts[i] = fmt.Sprintf("%d %s", counts[state], state)
	}
	return strings.Join(parts, ", ")
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// closeAll closes every host's link, as the control plane stops; each host reconnects to the
// next one that starts.
func (s *server) closeAll() {
	s.mu.Lock()
	s.stopping = true
	links := make([]*link, 0, len(s.links))
	for _, l := range s.links {
		links = append(links, l)
	}
	s.mu.Unlock()
	// Closed politely, so each host knows the control plane went away rather than the network,
	// but all at once and for at most 2 s.
	var wg sync.WaitGroup
	for _, l := range links {
		wg.Add(1)
		go func() {
			defer wg.Done()
			l.conn.Close(websocket.StatusGoingAway, "the control plane is stopping")
		}()
	}
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
}
