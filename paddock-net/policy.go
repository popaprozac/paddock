package main

import (
	"fmt"
	"strings"
	"sync/atomic"
)

// policy is the list of names a guest may reach. "example.com" matches that name only;
// "*.example.com" matches every name under example.com, but not example.com itself. An empty
// policy matches nothing.
type policy struct {
	names    map[string]bool
	suffixes []string // ".example.com" for "*.example.com"
}

func newPolicy(entries []string) (*policy, error) {
	p := &policy{names: map[string]bool{}}
	for _, entry := range entries {
		entry = normalize(entry)
		if entry == "" {
			continue
		}
		name, wildcard := strings.CutPrefix(entry, "*.")
		if !isHostName(name) {
			return nil, fmt.Errorf("%q is not a host name or *.domain", entry)
		}
		if wildcard {
			p.suffixes = append(p.suffixes, "."+name)
		} else {
			p.names[name] = true
		}
	}
	return p, nil
}

func (p *policy) allows(name string) bool {
	name = normalize(name)
	if p.names[name] {
		return true
	}
	for _, suffix := range p.suffixes {
		if strings.HasSuffix(name, suffix) {
			return true
		}
	}
	return false
}

// holding returns a holder for the policy in force, which paddock replaces at Assign.
func holding(p *policy) *atomic.Pointer[policy] {
	var current atomic.Pointer[policy]
	current.Store(p)
	return &current
}

// normalize lowercases a name's ASCII letters and drops the trailing dot of a fully qualified
// one. Only ASCII: Unicode lowercasing turns gİthub.com into github.com, so a name unlike any on
// the list would pass as one on it.
func normalize(name string) string {
	lower := strings.Map(func(r rune) rune {
		if 'A' <= r && r <= 'Z' {
			return r + 'a' - 'A'
		}
		return r
	}, strings.TrimSpace(name))
	return strings.TrimSuffix(lower, ".")
}

// isHostName accepts dot-separated labels of lowercase letters, digits and inner hyphens.
func isHostName(name string) bool {
	if name == "" || len(name) > 253 {
		return false
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
				return false
			}
		}
	}
	return true
}
