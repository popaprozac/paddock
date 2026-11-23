package main

import "testing"

func TestPolicyMatchesNamesAndSubdomains(t *testing.T) {
	p, err := newPolicy([]string{"github.com", " *.githubusercontent.com", "Example.ORG."})
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]bool{
		"github.com":                         true,
		"GitHub.com.":                        true,
		"api.github.com":                     false, // an exact entry doesn't cover subdomains
		"raw.githubusercontent.com":          true,
		"a.b.githubusercontent.com":          true,
		"githubusercontent.com":              false, // a wildcard doesn't cover the domain itself
		"evilgithubusercontent.com":          false,
		"githubusercontent.com.evil.example": false,
		"example.org":                        true,
		"":                                   false,
	} {
		if got := p.allows(name); got != want {
			t.Errorf("allows(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestEmptyPolicyAllowsNothing(t *testing.T) {
	p, err := newPolicy(nil)
	if err != nil {
		t.Fatal(err)
	}
	if p.allows("github.com") {
		t.Error("an empty policy allowed github.com")
	}
}

func TestPolicyRefusesEntriesThatAreNotNames(t *testing.T) {
	for _, entry := range []string{"*", "*.", "a..b", "-a.com", "a_b.com", "*.*.com", "1.2.3.4:443", "http://a.com"} {
		if _, err := newPolicy([]string{entry}); err == nil {
			t.Errorf("newPolicy accepted %q", entry)
		}
	}
}
