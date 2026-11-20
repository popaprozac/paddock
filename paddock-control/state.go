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

// kind is what an identity may do: a host serves VMs and reports its slots; a client, a
// person's CLI or an agent, asks for them. A token makes one kind only, so a login token can't
// add a Mac to the pool and a join token can't log anyone in.
type kind string

const (
	hostKind   kind = "host"
	clientKind kind = "client"
)

// tokenPrefix starts every token of a kind, so one pasted in the wrong place is recognizable.
func (k kind) tokenPrefix() string {
	if k == clientKind {
		return "pl1."
	}
	return "pj1."
}

// enrolled is a host or client that joined with a token. Its private key never left it; the
// control plane keeps only the public key, to check the signature each link starts with.
type enrolled struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	PublicKey []byte    `json:"publicKey"` // PKIX DER of a P-256 key
	Enrolled  time.Time `json:"enrolled"`
	LastSeen  time.Time `json:"lastSeen,omitzero"` // its last link's open or close; none if it never linked
}

// pendingToken is a token not yet used, kept only as the SHA-256 of its secret.
type pendingToken struct {
	Kind    kind      `json:"kind,omitempty"` // none: a join token from before there were kinds
	Created time.Time `json:"created"`
	Expires time.Time `json:"expires"`
}

func (t pendingToken) kind() kind {
	if t.Kind == "" {
		return hostKind
	}
	return t.Kind
}

// state is everything the control plane keeps on disk, in one file only its user can read.
type state struct {
	path string
	mu   sync.Mutex
	data struct {
		Hosts    map[string]*enrolled    `json:"hosts"`
		Clients  map[string]*enrolled    `json:"clients,omitempty"`
		Tokens   map[string]pendingToken `json:"tokens"`             // by hex SHA-256 of the secret
		Handouts map[string]*handout     `json:"handouts,omitempty"` // by VM name
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
		s.data.Hosts = map[string]*enrolled{}
	}
	if s.data.Clients == nil {
		s.data.Clients = map[string]*enrolled{}
	}
	if s.data.Tokens == nil {
		s.data.Tokens = map[string]pendingToken{}
	}
	if s.data.Handouts == nil {
		s.data.Handouts = map[string]*handout{}
	}
	return s, nil
}

// handout is a VM the pool handed to a client: only that client may use or release it. Kept on
// disk, so a restarted control plane still knows whose VMs its Macs are running.
type handout struct {
	VM     string    `json:"vm"`
	Host   string    `json:"host"`
	Client string    `json:"client"`
	Image  string    `json:"image,omitempty"`
	Since  time.Time `json:"since"`
}

func (s *state) addHandout(h handout) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Handouts[h.VM] = &h
	return s.save()
}

// handout is the hand-out of this VM, or nil.
func (s *state) handout(vm string) *handout {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h := s.data.Handouts[vm]; h != nil {
		copied := *h
		return &copied
	}
	return nil
}

// removeHandout forgets the VM's hand-out and says whether there was one, so that of the paths
// racing to end it, such as a release and the Mac's report without the VM, only one records it.
func (s *state) removeHandout(vm string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.data.Handouts[vm] == nil {
		return false, nil
	}
	delete(s.data.Handouts, vm)
	return true, s.save()
}

// handoutsWhere is every hand-out that match picks.
func (s *state) handoutsWhere(match func(handout) bool) []handout {
	s.mu.Lock()
	defer s.mu.Unlock()
	var list []handout
	for _, h := range s.data.Handouts {
		if match(*h) {
			list = append(list, *h)
		}
	}
	return list
}

// save writes the state; the caller holds mu.
func (s *state) save() error {
	data, err := json.MarshalIndent(&s.data, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(s.path, data)
}

// members is the map of enrolled identities of a kind; the caller holds mu.
func (s *state) members(k kind) map[string]*enrolled {
	if k == clientKind {
		return s.data.Clients
	}
	return s.data.Hosts
}

// newToken makes a single-use token of kind k that expires after ttl. The token carries the CA's
// pin, so whoever uses it trusts this control plane and nothing else.
func (s *state) newToken(k kind, pin []byte, ttl time.Duration, now time.Time) (string, time.Time, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", time.Time{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(now)
	expires := now.Add(ttl)
	s.data.Tokens[tokenKey(secret)] = pendingToken{Kind: k, Created: now, Expires: expires}
	if err := s.save(); err != nil {
		return "", time.Time{}, err
	}
	encode := base64.RawURLEncoding.EncodeToString
	return k.tokenPrefix() + encode(secret) + "." + encode(pin), expires, nil
}

// parseToken splits a token into its kind, its secret and the CA pin it carries.
func parseToken(token string) (k kind, secret, pin []byte, err error) {
	token = strings.TrimSpace(token)
	notAToken := errors.New("not a paddock join or login token")
	var rest string
	switch {
	case strings.HasPrefix(token, hostKind.tokenPrefix()):
		k, rest = hostKind, strings.TrimPrefix(token, hostKind.tokenPrefix())
	case strings.HasPrefix(token, clientKind.tokenPrefix()):
		k, rest = clientKind, strings.TrimPrefix(token, clientKind.tokenPrefix())
	default:
		return "", nil, nil, notAToken
	}
	parts := strings.Split(rest, ".")
	if len(parts) != 2 {
		return "", nil, nil, notAToken
	}
	secret, err = base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || len(secret) != 32 {
		return "", nil, nil, notAToken
	}
	pin, err = base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(pin) != sha256.Size {
		return "", nil, nil, notAToken
	}
	return k, secret, pin, nil
}

// errWrongKind is a token of the other kind: kept, so a token pasted in the wrong place still
// works where it belongs.
var errWrongKind = errors.New("a token of the other kind")

// useToken spends the token with this secret if it exists, hasn't expired and is of kind k. A
// token is found by the hash of its secret, so the stored hashes are no use to whoever reads them.
func (s *state) useToken(secret []byte, k kind, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(now)
	key := tokenKey(secret)
	token, ok := s.data.Tokens[key]
	if !ok {
		return false, nil
	}
	if token.kind() != k {
		return false, errWrongKind
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

// enroll keeps a new host's or client's public key under a new ID.
func (s *state) enroll(k kind, name string, publicKey []byte, now time.Time) (*enrolled, error) {
	if _, err := parseMemberKey(publicKey); err != nil {
		return nil, err
	}
	if err := validateName(name); err != nil {
		return nil, err
	}
	id := make([]byte, 8)
	if _, err := rand.Read(id); err != nil {
		return nil, err
	}
	member := &enrolled{ID: string(k) + "-" + hex.EncodeToString(id), Name: name, PublicKey: publicKey, Enrolled: now}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.members(k)[member.ID] = member
	if err := s.save(); err != nil {
		delete(s.members(k), member.ID)
		return nil, err
	}
	return member, nil
}

// member is the enrolled host or client with this ID, or nil.
func (s *state) member(k kind, id string) *enrolled {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.members(k)[id]
}

// seen keeps now as when the host or client with this ID was last linked. It saves only once a
// minute has passed, the precision the lists show, so a burst of short client links doesn't
// rewrite the state for each.
func (s *state) seen(k kind, id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	member := s.members(k)[id]
	if member == nil || now.Sub(member.LastSeen) < time.Minute {
		return nil
	}
	member.LastSeen = now
	return s.save()
}

// list is every enrolled identity of a kind.
func (s *state) list(k kind) []enrolled {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := make([]enrolled, 0, len(s.members(k)))
	for _, member := range s.members(k) {
		list = append(list, *member)
	}
	return list
}

// remove deletes the identity of kind k with this ID, or the only one with this name.
func (s *state) remove(k kind, idOrName string) (*enrolled, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	members := s.members(k)
	member := members[idOrName]
	if member == nil {
		for _, candidate := range members {
			if candidate.Name == idOrName {
				if member != nil {
					return nil, fmt.Errorf("more than one %s is named %q: remove it by its ID", k, idOrName)
				}
				member = candidate
			}
		}
	}
	if member == nil {
		return nil, fmt.Errorf("no %s has the ID or name %q", k, idOrName)
	}
	delete(members, member.ID)
	if err := s.save(); err != nil {
		members[member.ID] = member
		return nil, err
	}
	return member, nil
}

// parseMemberKey reads a host's or client's public key, which must be P-256: what CryptoKit and
// the Secure Enclave make.
func parseMemberKey(der []byte) (*ecdsa.PublicKey, error) {
	parsed, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, errors.New("the public key isn't a PKIX key")
	}
	key, ok := parsed.(*ecdsa.PublicKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("the public key isn't P-256")
	}
	return key, nil
}

// validateName accepts a name for people to read: 1 to 64 printable characters.
func validateName(name string) error {
	if name == "" || len(name) > 64 {
		return errors.New("a name must be 1 to 64 characters")
	}
	for _, r := range name {
		if !unicode.IsPrint(r) {
			return errors.New("a name must be printable characters only")
		}
	}
	return nil
}
