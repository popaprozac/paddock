package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/coder/websocket"
)

// The admin socket is how `paddock-control join-token`, `hosts` and `remove-host` reach the
// running control plane: a Unix socket in its state folder, which only its user can open, so no
// admin request ever crosses a network.

type adminRequest struct {
	Op   string        `json:"op"`             // join-token, login-token, hosts, clients, remove-host, remove-client
	Host string        `json:"host,omitempty"` // remove-host and remove-client: ID or name
	TTL  time.Duration `json:"ttl,omitempty"`  // join-token: how long it lasts
}

type adminResponse struct {
	Error   string         `json:"error,omitempty"`
	Token   string         `json:"token,omitempty"`
	Expires time.Time      `json:"expires,omitzero"`
	URLs    []string       `json:"urls,omitempty"` // join-token: the addresses hosts may use
	Hosts   []hostStatus   `json:"hosts,omitempty"`
	Clients []clientStatus `json:"clients,omitempty"`
	Removed string         `json:"removed,omitempty"`
}

func adminSocketPath(dir string) string {
	return filepath.Join(dir, "admin.sock")
}

// listenAdmin serves admin requests on the socket until the listener closes.
func (s *server) listenAdmin(path string, urls func() []string) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		listener.Close()
		return nil, err
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go s.serveAdmin(conn, urls)
		}
	}()
	return listener, nil
}

func (s *server) serveAdmin(conn net.Conn, urls func() []string) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	var request adminRequest
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&request); err != nil {
		return
	}
	_ = json.NewEncoder(conn).Encode(s.admin(request, urls))
}

func (s *server) admin(request adminRequest, urls func() []string) adminResponse {
	switch request.Op {
	case "join-token", "login-token":
		k := hostKind
		if request.Op == "login-token" {
			k = clientKind
		}
		ttl := request.TTL
		if ttl <= 0 {
			ttl = defaultTokenTTL
		}
		if ttl > maxTokenTTL {
			return adminResponse{Error: fmt.Sprintf("a join token lasts at most %s", maxTokenTTL)}
		}
		token, expires, err := s.state.newToken(k, s.authority.pin(), ttl, s.now())
		if err != nil {
			return adminResponse{Error: err.Error()}
		}
		s.audit.record(auditEvent{Event: request.Op + "-made", Reason: "expires " + expires.UTC().Format(time.RFC3339)})
		return adminResponse{Token: token, Expires: expires, URLs: urls()}
	case "hosts":
		return adminResponse{Hosts: s.status()}
	case "clients":
		return adminResponse{Clients: s.clientStatus()}
	case "remove-host":
		host, err := s.state.remove(hostKind, request.Host)
		if err != nil {
			return adminResponse{Error: err.Error()}
		}
		s.disconnect(host.ID)
		s.audit.record(auditEvent{Event: "host-removed", Host: host.ID, Name: host.Name})
		log.Printf("removed %s (%s)", host.Name, host.ID)
		return adminResponse{Removed: host.ID}
	case "remove-client":
		client, err := s.state.remove(clientKind, request.Host)
		if err != nil {
			return adminResponse{Error: err.Error()}
		}
		s.disconnectClient(client.ID, websocket.StatusPolicyViolation, "this client was removed from the control plane")
		s.audit.record(auditEvent{Event: "client-removed", Client: client.ID, Name: client.Name})
		log.Printf("removed client %s (%s)", client.Name, client.ID)
		return adminResponse{Removed: client.ID}
	default:
		return adminResponse{Error: fmt.Sprintf("unknown admin request %q", request.Op)}
	}
}

// askAdmin sends one request to the running control plane's admin socket.
func askAdmin(dir string, request adminRequest) (adminResponse, error) {
	conn, err := net.DialTimeout("unix", adminSocketPath(dir), 2*time.Second)
	if err != nil {
		return adminResponse{}, fmt.Errorf("the control plane isn't running with its state in %s (start it with 'paddock-control run')", dir)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := json.NewEncoder(conn).Encode(request); err != nil {
		return adminResponse{}, err
	}
	var response adminResponse
	if err := json.NewDecoder(conn).Decode(&response); err != nil {
		return adminResponse{}, err
	}
	if response.Error != "" {
		return response, errors.New(response.Error)
	}
	return response, nil
}
