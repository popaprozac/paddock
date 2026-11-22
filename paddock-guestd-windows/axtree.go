package main

// The accessibility tree of the app in front on the desktop, read through UI Automation, in the
// shape paddock-session gives for macOS (Sources/paddock-session/AXTree.swift) and the Linux agent
// for AT-SPI: roles are UI Automation's control types, such as "Button", and a frame is x, y,
// width and height in screen pixels.
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

// element is what the tree needs of one UI Automation element: its own fields, without children,
// and its children. uiaElement reads one.
type element interface {
	node() axNode
	children() []element
}

// describe describes e and, while the budget lasts, its children, as macOS's tree does.
func describe(e element, depth int, budget *int) axNode {
	*budget--
	n := e.node()
	n.Title, n.Value, n.Description, n.Identifier = cut(n.Title), cut(n.Value), cut(n.Description), cut(n.Identifier)
	if n.Role == "" {
		n.Role = "unknown"
	}
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

// app is the app in front: its process's name above its windows on screen, as macOS's tree has
// the app above its windows. UI Automation itself has no element for an app.
type app struct {
	name    string
	windows []element
}

func (a app) node() axNode        { return axNode{Role: "Application", Title: a.name, Enabled: true} }
func (a app) children() []element { return a.windows }

// controlTypes are UI Automation's control type names, by id from 50000 (UIAutomationClient.h).
var controlTypes = []string{
	"Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List", "Menu",
	"MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner", "StatusBar", "Tab",
	"TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom", "Group", "Thumb", "DataGrid",
	"DataItem", "Document", "SplitButton", "Window", "Pane", "Header", "HeaderItem", "Table", "TitleBar",
	"Separator", "SemanticZoom", "AppBar",
}

// controlTypeName is the name of control type `id`, or "" for one it doesn't know.
func controlTypeName(id int32) string {
	if i := int(id) - 50000; i >= 0 && i < len(controlTypes) {
		return controlTypes[i]
	}
	return ""
}
