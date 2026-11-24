package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io/fs"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// authority is the control plane's own certificate authority. Hosts and clients trust it, and
// nothing else, for the control plane's TLS: its pin is in every join token.
type authority struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
}

// loadOrCreateAuthority reads the CA from dir, or makes one on the first run. Its key never
// leaves dir.
func loadOrCreateAuthority(dir string) (*authority, error) {
	certPath, keyPath := filepath.Join(dir, "ca.crt"), filepath.Join(dir, "ca.key")
	certPEM, err := os.ReadFile(certPath)
	if errors.Is(err, fs.ErrNotExist) {
		return createAuthority(certPath, keyPath)
	} else if err != nil {
		return nil, err
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}
	certBlock, keyBlock := pemBlock(certPEM, "CERTIFICATE"), pemBlock(keyPEM, "PRIVATE KEY")
	if certBlock == nil || keyBlock == nil {
		return nil, fmt.Errorf("%s or %s isn't PEM", certPath, keyPath)
	}
	cert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, err
	}
	parsed, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || !key.PublicKey.Equal(cert.PublicKey) {
		return nil, fmt.Errorf("%s doesn't hold the key for %s", keyPath, certPath)
	}
	return &authority{cert: cert, key: key}, nil
}

func createAuthority(certPath, keyPath string) (*authority, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          randomSerial(),
		Subject:               pkix.Name{CommonName: "paddock control plane CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(20, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	// The key first: a certificate without its key would be read back as a broken CA.
	if err := writePrivate(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})); err != nil {
		return nil, err
	}
	if err := writePrivate(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &authority{cert: cert, key: key}, nil
}

// pin is the SHA-256 of the CA's public key, as hosts check it: the key, not the certificate,
// so a renewed CA certificate with the same key keeps every host enrolled.
func (a *authority) pin() []byte {
	sum := sha256.Sum256(a.cert.RawSubjectPublicKeyInfo)
	return sum[:]
}

// serverCertificate is a TLS certificate for every name and address in reach, signed by the CA,
// with the CA's certificate after it so a host can check the pin.
func (a *authority) serverCertificate(r reach) (*tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: randomSerial(),
		Subject:      pkix.Name{CommonName: "paddock control plane"},
		DNSNames:     r.names,
		IPAddresses:  r.addresses,
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(0, 0, 30),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, a.cert, &key.PublicKey, a.key)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{Certificate: [][]byte{der, a.cert.Raw}, PrivateKey: key, Leaf: leaf}, nil
}

// reach is the names and addresses hosts and clients may use for the control plane.
type reach struct {
	names     []string
	addresses []net.IP
}

// currentReach is this machine's name, with .local for Bonjour, localhost, every --name, and the
// addresses of its interfaces that are up: LAN, Tailscale (100.x) and loopback.
func currentReach(extra []string) reach {
	var r reach
	seen := map[string]bool{}
	addName := func(name string) {
		name = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(name)), ".")
		if name != "" && !seen[name] {
			seen[name] = true
			r.names = append(r.names, name)
		}
	}
	if host, err := os.Hostname(); err == nil {
		addName(host)
		if base, ok := strings.CutSuffix(strings.ToLower(host), ".local"); ok {
			addName(base)
		} else if !strings.Contains(host, ".") {
			addName(host + ".local")
		}
	}
	addName("localhost")
	for _, name := range extra {
		if ip := net.ParseIP(name); ip != nil {
			r.addresses = append(r.addresses, ip)
		} else {
			addName(name)
		}
	}
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLinkLocalUnicast() {
				r.addresses = append(r.addresses, ipnet.IP)
			}
		}
	}
	return r
}

// certificates serves the TLS certificate, made again every hour with the names and addresses the
// machine has then, and sooner for a Mac or client asking for a name or address it doesn't cover,
// so a new DHCP or Tailscale address is covered within a minute, without a restart.
type certificates struct {
	authority *authority
	extra     []string
	mu        sync.Mutex
	current   *tls.Certificate
	made      time.Time
}

func (c *certificates) get(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	age := time.Since(c.made)
	// At most once a minute, so a caller asking for a name this machine doesn't have can't make
	// it sign certificates without end.
	if c.current == nil || age > time.Hour || age > time.Minute && !covers(c.current.Leaf, hello) {
		cert, err := c.authority.serverCertificate(currentReach(c.extra))
		if err != nil {
			return nil, err
		}
		c.current, c.made = cert, time.Now()
	}
	return c.current, nil
}

// covers says whether cert is good for the name the caller asked for, or, connecting by address,
// the address it reached.
func covers(cert *x509.Certificate, hello *tls.ClientHelloInfo) bool {
	asked := hello.ServerName
	if asked == "" && hello.Conn != nil {
		asked, _, _ = net.SplitHostPort(hello.Conn.LocalAddr().String())
	}
	return asked == "" || cert.VerifyHostname(asked) == nil
}

func randomSerial() *big.Int {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		panic(err) // crypto/rand doesn't fail on the systems paddock runs on
	}
	return serial
}

func pemBlock(data []byte, kind string) *pem.Block {
	block, _ := pem.Decode(data)
	if block == nil || block.Type != kind {
		return nil
	}
	return block
}

// writePrivate writes data readable only by this user, through a temporary file and a rename, so
// a crash never leaves half a file.
func writePrivate(path string, data []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}
