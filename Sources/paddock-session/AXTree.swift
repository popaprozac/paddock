import AppKit
import ApplicationServices
import Foundation
import PaddockCore

/// One element of an app's accessibility tree. `frame` is x, y, width and height in screen
/// points, from the top left of the main display; with paddock's VM display a point is a pixel of
/// a screenshot.
struct AXNode: Encodable {
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    var description: String?
    var identifier: String?
    var frame: [Int]?
    var enabled: Bool?
    var focused: Bool?
    var children: [AXNode]?
}

enum AXTree {
    static let maxNodes = 5000
    static let maxDepth = 50
    static let maxText = 500

    /// The focused app's tree as indented JSON.
    static func focusedAppJSON() throws -> String {
        let systemWide = AXUIElementCreateSystemWide()
        // Applies to every element: an app that hangs costs at most this per attribute.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var budget = maxNodes
        let app = try frontmostApp(systemWide)
        let tree = node(app, depth: 0, budget: &budget)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(tree), as: UTF8.self)
    }

    /// Describes `element` and, while the budget lasts, its children. Past the budget or the
    /// depth limit, children are left out.
    static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var node = AXNode(role: text(element, kAXRoleAttribute) ?? "AXUnknown")
        node.subrole = text(element, kAXSubroleAttribute)
        node.title = text(element, kAXTitleAttribute)
        node.value = text(element, kAXValueAttribute)
        node.description = text(element, kAXDescriptionAttribute)
        node.identifier = text(element, kAXIdentifierAttribute)
        node.enabled = attribute(element, kAXEnabledAttribute) as? Bool
        node.focused = attribute(element, kAXFocusedAttribute) as? Bool
        if let origin: CGPoint = geometry(element, kAXPositionAttribute, .cgPoint),
           let size: CGSize = geometry(element, kAXSizeAttribute, .cgSize) {
            // Int(exactly:), where Int() traps: an app can report a null or infinite rectangle.
            let frame = [origin.x, origin.y, size.width, size.height].compactMap { Int(exactly: $0.rounded()) }
            if frame.count == 4 { node.frame = frame }
        }
        if depth < maxDepth, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty {
            var described: [AXNode] = []
            for child in children where budget > 0 {
                described.append(self.node(child, depth: depth + 1, budget: &budget))
            }
            node.children = described
        }
        return node
    }

    /// The app in front: from NSWorkspace, which a LaunchAgent can always ask, or else from the
    /// accessibility API's focused application, which a LaunchAgent sometimes can't get.
    static func frontmostApp(_ systemWide: AXUIElement) throws -> AXUIElement {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return AXUIElementCreateApplication(pid)
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw PaddockError("no app is in front (accessibility error \(result.rawValue))")
        }
        return (value as! AXUIElement)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// A string or number attribute as text, cut to `maxText` characters; nil when empty.
    static func text(_ element: AXUIElement, _ name: String) -> String? {
        let value = attribute(element, name)
        let string = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let string, !string.isEmpty else { return nil }
        return string.count > maxText ? String(string.prefix(maxText)) + "…" : string
    }

    static func geometry<T>(_ element: AXUIElement, _ name: String, _ type: AXValueType) -> T? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(value as! AXValue, type, pointer) else { return nil }
        return pointer.pointee
    }
}
