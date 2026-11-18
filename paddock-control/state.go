package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
)

// enrolledHost is a Mac that joined with a token. Its private key never left it; the control plane
// keeps only the public key, to check the signature each link starts with.
type enrolledHost struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	PublicKey []byte    `json:"publicKey"` // PKIX DER of a P-256 key
	Enrolled  time.Time `json:"enrolled"`
}

// pendingToken is a join token not yet used, kept only as the SHA-256 of its secret.
type pendingToken struct {
	Created time.Time `json:"created"`
	Expires time.Time `json:"expires"`
}

// state is everything the control plane keeps on disk, in one file only its user can read.
type state struct {
	path string
	mu   sync.Mutex
	data struct {
		Hosts  map[string]*enrolledHost `json:"hosts"`
		Tokens map[string]pendingToken  `json:"tokens"` // by hex SHA-256 of the secret
	}
}

func openState(dir string) (*state, error) {
	s := &state{path: filepath.Join(dir, "state.json")}
	data, err := os.ReadFile(s.path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(data, &s.data); err != nil {
			return nil, fmt.Errorf("%s: %w", s.path, err)
		}
	}
	if s.data.Hosts == nil {
		s.data.Hosts = map[string]*enrolledHost{}
	}
	if s.data.Tokens == nil {
		s.data.Tokens = map[string]pendingToken{}
	}
	return s, nil
}

// save writes the state; the caller holds mu.
func (s *state) save() error {
	data, err := json.MarshalIndent(&s.data, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(s.path, data)
}

// joinTokenPrefix starts every join token, so one pasted in the wrong place is recognizable.
const joinTokenPrefix = "pj1."

// newJoinToken makes a single-use token that expires after ttl. The token carries the CA's pin,
// so a host that has it trusts this control plane and nothing else.
func (s *state) newJoinToken(pin []byte, ttl time.Duration, now time.Time) (string, time.Time, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", time.Time{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(now)
	expires := now.Add(ttl)
	s.data.Tokens[tokenKey(secret)] = pendingToken{Created: now, Expires: expires}
	if err := s.save(); err != nil {
		return "", time.Time{}, err
	}
	encode := base64.RawURLEncoding.EncodeToString
	return joinTokenPrefix + encode(secret) + "." + encode(pin), expires, nil
}

// parseJoinToken splits a token into its secret and the CA pin it carries.
func parseJoinToken(token string) (secret, pin []byte, err error) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(token), joinTokenPrefix)
	parts := strings.Split(rest, ".")
	if !ok || len(parts) != 2 {
		return nil, nil, errors.New("not a paddock join token")
	}
	secret, err = base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || len(secret) != 32 {
		return nil, nil, errors.New("not a paddock join token")
	}
	pin, err = base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(pin) != sha256.Size {
		return nil, nil, errors.New("not a paddock join token")
	}
	return secret, pin, nil
}

// useJoinToken spends the token with this secret, if it exists and hasn't expired. A token is
// found by the hash of its secret, so the stored hashes are no use to whoever reads them.
func (s *state) useJoinToken(secret []byte, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(now)
	key := tokenKey(secret)
	if _, ok := s.data.Tokens[key]; !ok {
		return false, nil
	}
	delete(s.data.Tokens, key)
	return true, s.save()
}

// prune drops expired tokens; the caller holds mu and saves.
func (s *state) prune(now time.Time) {
	for key, token := range s.data.Tokens {
		if !now.Before(token.Expires) {
			delete(s.data.Tokens, key)
		}
	}
}

func tokenKey(secret []byte) string {
	sum := sha256.Sum256(secret)
	return hex.EncodeToString(sum[:])
}

// enroll keeps a new host's public key under a new ID.
func (s *state) enroll(name string, publicKey []byte, now time.Time) (*enrolledHost, error) {
	if _, err := parseHostKey(publicKey); err != nil {
		return nil, err
	}
	if err := validateHostName(name); err != nil {
		return nil, err
	}
	id := make([]byte, 8)
	if _, err := rand.Read(id); err != nil {
		return nil, err
	}
	host := &enrolledHost{ID: "host-" + hex.EncodeToString(id), Name: name, PublicKey: publicKey, Enrolled: now}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Hosts[host.ID] = host
	if err := s.save(); err != nil {
		delete(s.data.Hosts, host.ID)
		return nil, err
	}
	return host, nil
}

// host is the enrolled host with this ID, or nil.
func (s *state) host(id string) *enrolledHost {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.data.Hosts[id]
}

// hosts is every enrolled host.
func (s *state) hosts() []enrolledHost {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := make([]enrolledHost, 0, len(s.data.Hosts))
	for _, host := range s.data.Hosts {
		list = append(list, *host)
	}
	return list
}

// remove deletes the host with this ID, or the only one with this name.
func (s *state) remove(idOrName string) (*enrolledHost, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	host := s.data.Hosts[idOrName]
	if host == nil {
		for _, candidate := range s.data.Hosts {
			if candidate.Name == idOrName {
				if host != nil {
					return nil, fmt.Errorf("more than one host is named %q: remove it by its ID", idOrName)
				}
				host = candidate
			}
		}
	}
	if host == nil {
		return nil, fmt.Errorf("no host has the ID or name %q", idOrName)
	}
	delete(s.data.Hosts, host.ID)
	if err := s.save(); err != nil {
		s.data.Hosts[host.ID] = host
		return nil, err
	}
	return host, nil
}

// parseHostKey reads a host's public key, which must be P-256: what CryptoKit and the Secure
// Enclave make.
func parseHostKey(der []byte) (*ecdsa.PublicKey, error) {
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, errors.New("the host's public key isn't a PKIX key")
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("the host's public key isn't P-256")
	}
	return key, nil
}

// validateHostName accepts a name for people to read: 1 to 64 printable characters.
func validateHostName(name string) error {
	if name == "" || len(name) > 64 {
		return errors.New("a host's name must be 1 to 64 characters")
	}
	for _, r := range name {
		if !unicode.IsPrint(r) {
			return errors.New("a host's name must be printable characters only")
		}
	}
	return nil
}
