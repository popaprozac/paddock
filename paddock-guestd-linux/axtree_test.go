package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fake is an accessible object in memory, as AT-SPI would describe it.
type fake struct {
	roleName, name, desc, id string
	kinds                    []string
	state                    stateSet
	box                      []int
	content                  string
	number                   *float64
	kids                     []*fake
}

func (f *fake) role() string                         { return f.roleName }
func (f *fake) properties() (string, string, string) { return f.name, f.desc, f.id }
func (f *fake) states() stateSet                     { return f.state }
func (f *fake) text() string                         { return f.content }
func (f *fake) value() *float64                      { return f.number }
func (f *fake) extents() (int, int, int, int, bool) {
	if f.box == nil {
		return 0, 0, 0, 0, false
	}
	return f.box[0], f.box[1], f.box[2], f.box[3], true
}
func (f *fake) interfaces() map[string]bool {
	kinds := map[string]bool{}
	for _, k := range f.kinds {
		kinds["org.a11y.atspi."+k] = true
	}
	return kinds
}
func (f *fake) children() []element {
	out := make([]element, len(f.kids))
	for i, k := range f.kids {
		out[i] = k
	}
	return out
}

const (
	enabled = stateSet(1) << stateEnabled
	focused = stateSet(1) << stateFocused
	active  = stateSet(1) << stateActive
)

func TestDescribeGivesMacOSsShape(t *testing.T) {
	three := 3.0
	edit := &fake{roleName: "menu", name: "Edit", kinds: []string{"Component"}, state: enabled, box: []int{44, 56, 41, 25}}
	hidden := &fake{roleName: "menu item", name: "Copy", kinds: []string{"Component"}, state: enabled,
		box: []int{-2147483648, -2147483648, 1, 1}}
	field := &fake{roleName: "text", id: "query", kinds: []string{"Component", "Text"}, state: enabled | focused,
		box: []int{10, 10, 200, 20}, content: "hello"}
	slider := &fake{roleName: "slider", kinds: []string{"Value"}, number: &three}
	app := &fake{roleName: "application", name: "xfce4-terminal", kids: []*fake{edit, hidden, field, slider}}
	budget := axMaxNodes
	got, _ := json.Marshal(describe(app, 0, &budget))
	want := `{"role":"application","title":"xfce4-terminal","enabled":false,"focused":false,"children":[` +
		`{"role":"menu","title":"Edit","frame":[44,56,41,25],"enabled":true,"focused":false},` +
		`{"role":"menu item","title":"Copy","enabled":true,"focused":false},` +
		`{"role":"text","value":"hello","identifier":"query","frame":[10,10,200,20],"enabled":true,"focused":true},` +
		`{"role":"slider","value":"3","enabled":false,"focused":false}]}`
	if string(got) != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if budget != axMaxNodes-5 {
		t.Fatalf("budget %d", budget)
	}
}

func TestDescribeCutsTextAndStopsAtItsLimits(t *testing.T) {
	long := strings.Repeat("é", axMaxText+20)
	if n := describe(&fake{roleName: "label", name: long}, 0, new(int)); len([]rune(n.Title)) != axMaxText {
		t.Fatalf("title has %d characters", len([]rune(n.Title)))
	}
	// A chain deeper than the depth limit ends there.
	root := &fake{roleName: "panel"}
	for leaf, i := root, 0; i < axMaxDepth+10; i++ {
		child := &fake{roleName: "panel"}
		leaf.kids = []*fake{child}
		leaf = child
	}
	budget := axMaxNodes
	depth := 0
	for n := describe(root, 0, &budget); len(n.Children) > 0; n = n.Children[0] {
		depth++
	}
	if depth != axMaxDepth {
		t.Fatalf("tree went %d levels deep", depth)
	}
	// A wide tree stops at the node budget.
	wide := &fake{roleName: "list"}
	for i := 0; i < axMaxNodes+100; i++ {
		wide.kids = append(wide.kids, &fake{roleName: "list item"})
	}
	budget = axMaxNodes
	if n := describe(wide, 0, &budget); len(n.Children) != axMaxNodes-1 || budget != 0 {
		t.Fatalf("%d children, budget %d", len(n.Children), budget)
	}
}

func TestFocusedAppIsTheOneWithTheActiveWindow(t *testing.T) {
	panel := &fake{name: "xfce4-panel", kids: []*fake{{roleName: "frame"}}}
	// The window manager's own window, active but off screen, as xfwm4's is.
	wm := &fake{name: "xfwm4", kids: []*fake{{roleName: "window", state: active, box: []int{-1000, -1000, 5, 5}}}}
	terminal := &fake{name: "xfce4-terminal", kids: []*fake{{roleName: "frame"},
		{roleName: "frame", state: active, box: []int{0, 27, 827, 517}}}}
	if got := focusedApp([]element{panel, wm, terminal}); got != element(terminal) {
		t.Fatalf("got %v", got)
	}
	if got := focusedApp([]element{panel}); got != nil {
		t.Fatalf("got %v with no active window", got)
	}
}

// A bus that takes the connection and never answers fails the request once treeTimeout is up.
func TestTreeGivesUpOnABusThatNeverAnswers(t *testing.T) {
	defer func(was time.Duration) { treeTimeout = was }(treeTimeout)
	treeTimeout = 200 * time.Millisecond
	dir, err := os.MkdirTemp("", "ax") // short: a socket's path holds at most 103 bytes
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	listener, err := net.Listen("unix", filepath.Join(dir, "bus"))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	held := make(chan net.Conn, 1)
	go func() {
		if c, err := listener.Accept(); err == nil {
			held <- c
		}
	}()
	start := time.Now()
	_, err = treeOn("unix:path=" + filepath.Join(dir, "bus"))
	if err == nil || !strings.Contains(err.Error(), "took over 200ms") || time.Since(start) > 2*time.Second {
		t.Fatalf("got %v after %v, want the time it took over", err, time.Since(start))
	}
	(<-held).Close()
}

func TestUnknownRoleIsSaidSo(t *testing.T) {
	if n := describe(&fake{}, 0, new(int)); n.Role != "unknown" {
		t.Fatalf("role %q", n.Role)
	}
}
