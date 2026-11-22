package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// axtree sends the accessibility tree of the app in front on the desktop, as indented JSON a line
// at a time. UI Automation reads only the desktop of the session it runs in, so this binary runs
// again as the account signed in at the console and prints the tree.
func axtree(out *answerer) response {
	self, err := os.Executable()
	if err != nil {
		return failed("can't find the agent's own binary: " + err.Error())
	}
	reader, process, err := startPiped(self, `"`+self+`" axtree`, false)
	if err != nil {
		return failed("can't read the desktop: " + err.Error())
	}
	defer windows.CloseHandle(process)
	tree, _ := io.ReadAll(reader)
	reader.Close()
	if wait(process) != 0 {
		return failed(string(bytes.TrimSpace(tree)))
	}
	var lines []response
	for _, line := range bytes.Split(bytes.TrimRight(tree, "\r\n"), []byte("\n")) {
		lines = append(lines, output(line))
	}
	out.send(lines...)
	return exited(0)
}

// printFocusedTree prints the tree of the app in front as indented JSON. It runs as the account
// signed in at the console, in its session.
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

var (
	user32               = windows.NewLazySystemDLL("user32.dll")
	procSetDpiAwareness  = user32.NewProc("SetProcessDpiAwarenessContext")
	ole32                = windows.NewLazySystemDLL("ole32.dll")
	procCoCreateInstance = ole32.NewProc("CoCreateInstance")
	oleaut32             = windows.NewLazySystemDLL("oleaut32.dll")
	procSysFreeString    = oleaut32.NewProc("SysFreeString")
	procVariantClear     = oleaut32.NewProc("VariantClear")

	clsidCUIAutomation8 = guid("{e22ad333-b25f-460c-83d0-0581107395c9}")
	iidIUIAutomation2   = guid("{34723aff-0c9d-49d0-9896-7ab52df8cd8a}")
	iidTextPattern      = guid("{32eba289-3583-42c9-9c59-3b6d9a1e9b6a}")
)

func guid(s string) windows.GUID {
	g, err := windows.GUIDFromString(s)
	if err != nil {
		panic(err)
	}
	return g
}

// Method numbers in the method tables of UIAutomationClient.h's interfaces, counting
// QueryInterface, AddRef and Release as 0 to 2.
const (
	release = 2

	// IUIAutomation2
	elementFromHandleBuildCache = 10
	createCacheRequest          = 20
	putConnectionTimeout        = 61
	putTransactionTimeout       = 63

	// IUIAutomationCacheRequest
	addProperty  = 3
	putTreeScope = 7

	// IUIAutomationElement
	getCachedPropertyValue     = 12
	getCurrentPatternAs        = 14
	getCachedChildren          = 19
	getCachedControlType       = 53
	getCachedName              = 55
	getCachedHasKeyboardFocus  = 58
	getCachedIsEnabled         = 60
	getCachedAutomationID      = 61
	getCachedHelpText          = 63
	getCachedIsOffscreen       = 70
	getCachedBoundingRectangle = 75

	// IUIAutomationElementArray
	arrayLength     = 3
	arrayGetElement = 4

	// IUIAutomationTextPattern and IUIAutomationTextRange
	getDocumentRange = 7
	rangeGetText     = 12
)

// UI Automation's property and pattern ids (UIAutomationClient.h).
const (
	boundingRectangleProperty   = 30001
	controlTypeProperty         = 30003
	nameProperty                = 30005
	hasKeyboardFocusProperty    = 30008
	isEnabledProperty           = 30010
	automationIDProperty        = 30011
	helpTextProperty            = 30013
	isOffscreenProperty         = 30022
	isRangeValueAvailable       = 30033
	isTextAvailable             = 30040
	isValueAvailable            = 30043
	valueProperty               = 30045
	rangeValueProperty          = 30047
	fullDescriptionProperty     = 30159
	textPattern                 = 10014
	treeScopeSubtree            = 7
	dpiAwarenessPerMonitorAware = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, -4
)

// cachedProperties are what one request per window fetches of every element under it, in one
// call to its app.
var cachedProperties = []uintptr{
	boundingRectangleProperty, controlTypeProperty, nameProperty, hasKeyboardFocusProperty, isEnabledProperty,
	automationIDProperty, helpTextProperty, isOffscreenProperty, isRangeValueAvailable, isTextAvailable,
	isValueAvailable, valueProperty, rangeValueProperty, fullDescriptionProperty,
}

// focusedTree reads the app in front: the process of the window in front, and that process's
// windows on screen, each in UI Automation's control view.
//
// shortcut: an app whose windows a shared host process owns, as ApplicationFrameHost does for
// packaged apps such as Settings, comes with that host's other windows on screen; pick by the
// window in front alone if agents trip on it.
func focusedTree() (axNode, error) {
	// A process aware of each monitor's DPI gets frames in screen pixels, as screenshots have.
	procSetDpiAwareness.Call(dpiAwarenessPerMonitorAware)
	if err := windows.CoInitializeEx(0, windows.COINIT_MULTITHREADED); err != nil {
		return axNode{}, fmt.Errorf("can't start COM: %w", err)
	}
	defer windows.CoUninitialize()
	var uia *com
	r, _, _ := procCoCreateInstance.Call(uintptr(unsafe.Pointer(&clsidCUIAutomation8)), 0, windows.CLSCTX_INPROC_SERVER,
		uintptr(unsafe.Pointer(&iidIUIAutomation2)), uintptr(unsafe.Pointer(&uia)))
	if int32(r) < 0 {
		return axNode{}, fmt.Errorf("can't start UI Automation: HRESULT 0x%08X", uint32(r))
	}
	// An app that doesn't answer within 0.5 s, or takes over 2 s to give a window's tree, is
	// left out.
	uia.call(putConnectionTimeout, 500)
	uia.call(putTransactionTimeout, 2000)

	frontWindow := windows.GetForegroundWindow()
	if frontWindow == 0 {
		return axNode{}, errors.New("no window is in front on the desktop")
	}
	var pid uint32
	windows.GetWindowThreadProcessId(frontWindow, &pid)
	var request *com
	if err := uia.out(createCacheRequest, unsafe.Pointer(&request)); err != nil {
		return axNode{}, fmt.Errorf("can't ask UI Automation for the tree: %w", err)
	}
	for _, id := range cachedProperties {
		request.call(addProperty, id)
	}
	request.call(putTreeScope, treeScopeSubtree)

	// shortcut: the helper exits right after printing one tree, so the elements it reads are
	// never released.
	front := app{name: processName(pid)}
	for _, window := range windowsOf(pid) {
		var e *com
		if uia.out2(elementFromHandleBuildCache, uintptr(window), uintptr(unsafe.Pointer(request)), unsafe.Pointer(&e)) == nil && e != nil {
			front.windows = append(front.windows, uiaElement{e})
		}
	}
	if len(front.windows) == 0 {
		return axNode{}, fmt.Errorf("UI Automation can't read the windows of '%s'", front.name)
	}
	budget := axMaxNodes
	return describe(front, 0, &budget), nil
}

// windowsOf is process pid's top-level windows on screen, front to back.
func windowsOf(pid uint32) []windows.HWND {
	var found []windows.HWND
	windows.EnumWindows(windows.NewCallback(func(window windows.HWND, _ uintptr) uintptr {
		var owner uint32
		windows.GetWindowThreadProcessId(window, &owner)
		var cloaked uint32 // a window DWM hides, such as a suspended packaged app's, though "visible"
		windows.DwmGetWindowAttribute(window, windows.DWMWA_CLOAKED, unsafe.Pointer(&cloaked), 4)
		if owner == pid && windows.IsWindowVisible(window) && cloaked == 0 {
			found = append(found, window)
		}
		return 1
	}), nil)
	return found
}

// processName is the file name of process pid's program without ".exe", such as "Notepad".
func processName(pid uint32) string {
	process, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(process)
	buffer := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(buffer))
	if windows.QueryFullProcessImageName(process, 0, &buffer[0], &size) != nil {
		return ""
	}
	name := filepath.Base(windows.UTF16ToString(buffer[:size]))
	return strings.TrimSuffix(name, filepath.Ext(name))
}

// uiaElement is one UI Automation element, with its tree cached by focusedTree's request.
type uiaElement struct{ e *com }

func (u uiaElement) node() axNode {
	var controlType, offscreen, enabled, focused int32
	u.e.out(getCachedControlType, unsafe.Pointer(&controlType))
	u.e.out(getCachedIsOffscreen, unsafe.Pointer(&offscreen))
	u.e.out(getCachedIsEnabled, unsafe.Pointer(&enabled))
	u.e.out(getCachedHasKeyboardFocus, unsafe.Pointer(&focused))
	n := axNode{Role: controlTypeName(controlType), Title: u.text(getCachedName), Identifier: u.text(getCachedAutomationID),
		Value: u.value(), Enabled: enabled != 0, Focused: focused != 0}
	if n.Description = u.property(fullDescriptionProperty).text(); n.Description == "" {
		n.Description = u.text(getCachedHelpText)
	}
	var r windows.Rect
	if u.e.out(getCachedBoundingRectangle, unsafe.Pointer(&r)) == nil && offscreen == 0 && r.Right > r.Left && r.Bottom > r.Top {
		n.Frame = []int{int(r.Left), int(r.Top), int(r.Right - r.Left), int(r.Bottom - r.Top)}
	}
	return n
}

func (u uiaElement) children() []element {
	var list *com
	if u.e.out(getCachedChildren, unsafe.Pointer(&list)) != nil || list == nil {
		return nil
	}
	defer list.call(release)
	var count int32
	list.out(arrayLength, unsafe.Pointer(&count))
	var kids []element
	for i := int32(0); i < count; i++ {
		var child *com
		if list.out1(arrayGetElement, uintptr(i), unsafe.Pointer(&child)) == nil && child != nil {
			kids = append(kids, uiaElement{child})
		}
	}
	return kids
}

// value is a field's text, a slider's number, or a document's first axMaxText characters.
func (u uiaElement) value() string {
	switch {
	case u.property(isValueAvailable).boolean():
		return u.property(valueProperty).text()
	case u.property(isRangeValueAvailable).boolean():
		if v, ok := u.property(rangeValueProperty).number(); ok {
			return strconv.FormatFloat(v, 'f', -1, 64)
		}
	case u.property(isTextAvailable).boolean():
		return u.documentText()
	}
	return ""
}

// documentText asks the app for the element's text, which no cache holds.
func (u uiaElement) documentText() string {
	var pattern, document *com
	if u.e.out2(getCurrentPatternAs, textPattern, uintptr(unsafe.Pointer(&iidTextPattern)), unsafe.Pointer(&pattern)) != nil || pattern == nil {
		return ""
	}
	defer pattern.call(release)
	if pattern.out(getDocumentRange, unsafe.Pointer(&document)) != nil || document == nil {
		return ""
	}
	defer document.call(release)
	var s *uint16
	if document.out1(rangeGetText, axMaxText, unsafe.Pointer(&s)) != nil {
		return ""
	}
	return bstr(s)
}

// text calls a cached getter that gives a string.
func (u uiaElement) text(method int) string {
	var s *uint16
	if u.e.out(method, unsafe.Pointer(&s)) != nil {
		return ""
	}
	return bstr(s)
}

func (u uiaElement) property(id uintptr) variant {
	var v variant
	if u.e.out1(getCachedPropertyValue, id, unsafe.Pointer(&v)) != nil {
		return variant{}
	}
	return v
}

// bstr is a BSTR's text; it frees the BSTR.
func bstr(s *uint16) string {
	if s == nil {
		return ""
	}
	defer procSysFreeString.Call(uintptr(unsafe.Pointer(s)))
	return windows.UTF16PtrToString(s)
}

// variant is a VARIANT (oaidl.h): its type, then its value in the first word of 16 bytes.
type variant struct {
	vt    uint16
	_     [3]uint16
	value [2]uintptr
}

const (
	vtR8   = 5
	vtBSTR = 8
	vtBool = 11
)

func (v variant) boolean() bool { return v.vt == vtBool && int16(v.value[0]) != 0 }

func (v variant) number() (float64, bool) {
	return math.Float64frombits(uint64(v.value[0])), v.vt == vtR8
}

// text is a string variant's text; it clears the variant.
func (v variant) text() string {
	if v.vt != vtBSTR {
		return ""
	}
	s := windows.UTF16PtrToString(*(**uint16)(unsafe.Pointer(&v.value[0])))
	procVariantClear.Call(uintptr(unsafe.Pointer(&v)))
	return s
}

// com is a COM interface: its first word is the address of its method table. Each call wrapper
// passes Go pointers in syscall.SyscallN's own argument list, so the runtime keeps them valid.
type com struct{ methods *[90]uintptr }

func (c *com) call(method int, args ...uintptr) error {
	return hresult(syscall.SyscallN(c.methods[method], append([]uintptr{uintptr(unsafe.Pointer(c))}, args...)...))
}

// out calls a method whose only argument is where it puts its result.
func (c *com) out(method int, result unsafe.Pointer) error {
	return hresult(syscall.SyscallN(c.methods[method], uintptr(unsafe.Pointer(c)), uintptr(result)))
}

func (c *com) out1(method int, a uintptr, result unsafe.Pointer) error {
	return hresult(syscall.SyscallN(c.methods[method], uintptr(unsafe.Pointer(c)), a, uintptr(result)))
}

func (c *com) out2(method int, a, b uintptr, result unsafe.Pointer) error {
	return hresult(syscall.SyscallN(c.methods[method], uintptr(unsafe.Pointer(c)), a, b, uintptr(result)))
}

func hresult(r, _ uintptr, _ syscall.Errno) error {
	if int32(r) < 0 {
		return fmt.Errorf("HRESULT 0x%08X", uint32(r))
	}
	return nil
}
