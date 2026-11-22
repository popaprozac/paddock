package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// fake is a UI Automation element in memory: its fields as uiaElement reads them, and children.
type fake struct {
	n    axNode
	kids []*fake
}

func (f *fake) node() axNode { return f.n }
func (f *fake) children() []element {
	out := make([]element, len(f.kids))
	for i, k := range f.kids {
		out[i] = k
	}
	return out
}

func TestDescribeGivesMacOSsShapeUnderTheApp(t *testing.T) {
	bold := &fake{n: axNode{Role: "Button", Title: "Bold (Ctrl+B)", Frame: []int{746, 120, 32, 32}, Enabled: true}}
	tip := &fake{n: axNode{Role: "Window", Identifier: "PrivacyTeachingTip", Enabled: true}}
	text := &fake{n: axNode{Role: "Document", Title: "Text editor", Value: "hello", Frame: []int{84, 205, 1428, 664},
		Enabled: true, Focused: true}}
	window := &fake{n: axNode{Role: "Window", Title: "Untitled - Notepad", Frame: []int{78, 78, 1440, 843}, Enabled: true},
		kids: []*fake{text, bold, tip}}
	budget := axMaxNodes
	got, _ := json.Marshal(describe(app{name: "Notepad", windows: []element{window}}, 0, &budget))
	want := `{"role":"Application","title":"Notepad","enabled":true,"focused":false,"children":[` +
		`{"role":"Window","title":"Untitled - Notepad","frame":[78,78,1440,843],"enabled":true,"focused":false,"children":[` +
		`{"role":"Document","title":"Text editor","value":"hello","frame":[84,205,1428,664],"enabled":true,"focused":true},` +
		`{"role":"Button","title":"Bold (Ctrl+B)","frame":[746,120,32,32],"enabled":true,"focused":false},` +
		`{"role":"Window","identifier":"PrivacyTeachingTip","enabled":true,"focused":false}]}]}`
	if string(got) != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if budget != axMaxNodes-5 {
		t.Fatalf("budget %d", budget)
	}
}

func TestDescribeCutsTextAndStopsAtItsLimits(t *testing.T) {
	long := strings.Repeat("é", axMaxText+20)
	n := describe(&fake{n: axNode{Title: long, Value: long, Description: long, Identifier: long}}, 0, new(int))
	for _, s := range []string{n.Title, n.Value, n.Description, n.Identifier} {
		if len([]rune(s)) != axMaxText {
			t.Fatalf("text has %d characters", len([]rune(s)))
		}
	}
	if n.Role != "unknown" {
		t.Fatalf("role %q for an unknown control type", n.Role)
	}

	deep := &fake{}
	for i := 0; i < axMaxDepth+10; i++ {
		deep = &fake{kids: []*fake{deep}}
	}
	budget := axMaxNodes
	levels := 0
	for n := describe(deep, 0, &budget); len(n.Children) > 0; n = n.Children[0] {
		levels++
	}
	if levels != axMaxDepth {
		t.Fatalf("%d levels", levels)
	}

	wide := &fake{}
	for i := 0; i < axMaxNodes+100; i++ {
		wide.kids = append(wide.kids, &fake{})
	}
	budget = axMaxNodes
	if n := describe(wide, 0, &budget); len(n.Children) != axMaxNodes-1 || budget != 0 {
		t.Fatalf("%d children, budget %d", len(n.Children), budget)
	}
}

func TestControlTypeNames(t *testing.T) {
	for id, name := range map[int32]string{50000: "Button", 50004: "Edit", 50030: "Document", 50032: "Window",
		50033: "Pane", 50040: "AppBar", 49999: "", 50041: ""} {
		if got := controlTypeName(id); got != name {
			t.Errorf("control type %d: %q, want %q", id, got, name)
		}
	}
}
