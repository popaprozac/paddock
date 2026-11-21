package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/godbus/dbus/v5"
)

// The accessibility tree of the app in front on the desktop, read from AT-SPI, in the shape
// paddock-session gives for macOS (Sources/paddock-session/AXTree.swift): roles are AT-SPI's
// names, such as "push button", and a frame is x, y, width and height in screen pixels.
type axNode struct {
	Role        string   `json:"role"`
	Title       string   `json:"title,omitempty"`
	Value       string   `json:"value,omitempty"`
	Description string   `json:"description,omitempty"`
	Identifier  string   `json:"identifier,omitempty"`
	Frame       []int    `json:"frame,omitempty"`
	Enabled     bool     `json:"enabled"`
	Focused     bool     `json:"focused"`
	Children    []axNode `json:"children,omitempty"`
}

// The same limits as macOS's tree.
const (
	axMaxNodes = 5000
	axMaxDepth = 50
	axMaxText  = 500
)

// AT-SPI's state bits (atspi-constants.h), in the two words GetState returns.
const (
	stateActive  = 1
	stateEnabled = 8
	stateFocused = 12
)

type stateSet uint64

func (s stateSet) has(bit uint) bool { return s&(1<<bit) != 0 }

// element is what the tree needs of one accessible object; atspiElement reads one over D-Bus.
type element interface {
	role() string
	properties() (name, description, identifier string)
	interfaces() map[string]bool
	states() stateSet
	extents() (x, y, width, height int, ok bool)
	text() string    // a Text's first axMaxText characters
	value() *float64 // a Value's current value
	children() []element
}

// describe describes e and, while the budget lasts, its children, as macOS's tree does. An
// element off screen, which AT-SPI gives a 1x1 frame at the most negative coordinates, has none.
func describe(e element, depth int, budget *int) axNode {
	*budget--
	name, description, identifier := e.properties()
	n := axNode{Role: e.role(), Title: cut(name), Description: cut(description), Identifier: cut(identifier)}
	if n.Role == "" {
		n.Role = "unknown"
	}
	kinds := e.interfaces()
	if kinds["org.a11y.atspi.Text"] {
		n.Value = cut(e.text())
	} else if kinds["org.a11y.atspi.Value"] {
		if v := e.value(); v != nil {
			n.Value = fmt.Sprint(*v)
		}
	}
	if kinds["org.a11y.atspi.Component"] {
		if x, y, w, h, ok := e.extents(); ok && w > 1 && h > 1 && x > -100000 && y > -100000 {
			n.Frame = []int{x, y, w, h}
		}
	}
	s := e.states()
	n.Enabled, n.Focused = s.has(stateEnabled), s.has(stateFocused)
	if depth < axMaxDepth {
		for _, child := range e.children() {
			if *budget <= 0 {
				break
			}
			n.Children = append(n.Children, describe(child, depth+1, budget))
		}
	}
	return n
}

func cut(text string) string {
	if runes := []rune(text); len(runes) > axMaxText {
		return string(runes[:axMaxText])
	}
	return text
}

// focusedApp is the app whose window is active, as the window manager marks the one in front.
// Only a window at least partly on screen counts: xfwm4 keeps an active 5x5 window at -1000, -1000.
func focusedApp(apps []element) element {
	for _, app := range apps {
		for _, window := range app.children() {
			if !window.states().has(stateActive) {
				continue
			}
			if x, y, w, h, ok := window.extents(); ok && w > 1 && h > 1 && x+w > 0 && y+h > 0 {
				return app
			}
		}
	}
	return nil
}

// printFocusedTree prints the tree of the app in front as indented JSON. It runs as the
// account whose desktop it reads, which owns the session's AT-SPI bus.
func printFocusedTree(stdout, stderr io.Writer) int {
	tree, err := focusedTree()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	encoder := json.NewEncoder(stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(tree); err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}

func focusedTree() (axNode, error) {
	// at-spi-bus-launcher puts the bus in the account's runtime folder, named for the display.
	buses, _ := filepath.Glob(fmt.Sprintf("/run/user/%d/at-spi/bus*", os.Getuid()))
	if len(buses) == 0 {
		return axNode{}, errors.New("the desktop has no AT-SPI bus: install at-spi2-core in the golden image")
	}
	conn, err := dbus.Connect("unix:path=" + buses[0])
	if err != nil {
		return axNode{}, fmt.Errorf("can't reach the desktop's AT-SPI bus: %w", err)
	}
	defer conn.Close()
	desktop := atspiElement{conn: conn, dest: "org.a11y.atspi.Registry", path: "/org/a11y/atspi/accessible/root"}
	app := focusedApp(desktop.children())
	if app == nil {
		return axNode{}, errors.New("no app on the desktop has an active window")
	}
	budget := axMaxNodes
	return describe(app, 0, &budget), nil
}

// atspiElement is one accessible object on the AT-SPI bus. A call that fails or takes longer than
// callTimeout, as with an app that hangs, leaves out what it would have given.
type atspiElement struct {
	conn *dbus.Conn
	dest string
	path dbus.ObjectPath
}

const callTimeout = 500 * time.Millisecond

func (e atspiElement) call(method string, result any, args ...any) bool {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	return e.conn.Object(e.dest, e.path).CallWithContext(ctx, method, 0, args...).Store(result) == nil
}

func (e atspiElement) property(iface, name string, result any) bool {
	var v dbus.Variant
	return e.call("org.freedesktop.DBus.Properties.Get", &v, iface, name) && v.Store(result) == nil
}

func (e atspiElement) role() string {
	var role string
	e.call("org.a11y.atspi.Accessible.GetRoleName", &role)
	return role
}

func (e atspiElement) properties() (name, description, identifier string) {
	var all map[string]dbus.Variant
	if !e.call("org.freedesktop.DBus.Properties.GetAll", &all, "org.a11y.atspi.Accessible") {
		return "", "", ""
	}
	text := func(key string) string {
		s, _ := all[key].Value().(string)
		return s
	}
	return text("Name"), text("Description"), text("AccessibleId")
}

func (e atspiElement) interfaces() map[string]bool {
	var names []string
	e.call("org.a11y.atspi.Accessible.GetInterfaces", &names)
	kinds := map[string]bool{}
	for _, name := range names {
		kinds[name] = true
	}
	return kinds
}

func (e atspiElement) states() stateSet {
	var words []uint32
	if !e.call("org.a11y.atspi.Accessible.GetState", &words) || len(words) < 2 {
		return 0
	}
	return stateSet(words[0]) | stateSet(words[1])<<32
}

func (e atspiElement) extents() (x, y, width, height int, ok bool) {
	var box struct{ X, Y, Width, Height int32 }
	const screen = uint32(0) // ATSPI_COORD_TYPE_SCREEN
	if !e.call("org.a11y.atspi.Component.GetExtents", &box, screen) {
		return 0, 0, 0, 0, false
	}
	return int(box.X), int(box.Y), int(box.Width), int(box.Height), true
}

func (e atspiElement) text() string {
	var count int32
	if !e.property("org.a11y.atspi.Text", "CharacterCount", &count) || count <= 0 {
		return ""
	}
	var text string
	e.call("org.a11y.atspi.Text.GetText", &text, int32(0), min(count, axMaxText))
	return text
}

func (e atspiElement) value() *float64 {
	var v float64
	if !e.property("org.a11y.atspi.Value", "CurrentValue", &v) {
		return nil
	}
	return &v
}

func (e atspiElement) children() []element {
	var refs []struct {
		Name string
		Path dbus.ObjectPath
	}
	e.call("org.a11y.atspi.Accessible.GetChildren", &refs)
	elements := make([]element, 0, len(refs))
	for _, ref := range refs {
		elements = append(elements, atspiElement{conn: e.conn, dest: ref.Name, path: ref.Path})
	}
	return elements
}
