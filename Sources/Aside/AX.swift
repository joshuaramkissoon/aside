import ApplicationServices
import AppKit

/// Thin, forgiving wrappers over the Accessibility C API. Everything returns nil on any failure.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func param(_ el: AXUIElement, _ name: String, _ p: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, p, &v) == .success ? v : nil
    }

    static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    static func value(_ r: CFRange) -> AXValue {
        var r = r
        return AXValueCreate(.cfRange, &r)!
    }

    static func value(_ p: CGPoint) -> AXValue {
        var p = p
        return AXValueCreate(.cgPoint, &p)!
    }

    // Text markers: the public C functions work in both WebKit and Chromium
    // (Chromium doesn't answer AXStartTextMarkerForTextMarkerRange and friends).
    static func startMarker(_ r: CFTypeRef?) -> CFTypeRef? {
        guard let r, CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
    }

    static func endMarker(_ r: CFTypeRef?) -> CFTypeRef? {
        guard let r, CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyEndMarker(r as! AXTextMarkerRange)
    }

    /// A marker range between two markers, in whichever order they come.
    static func markerRange(_ el: AXUIElement, _ a: CFTypeRef?, _ b: CFTypeRef?) -> CFTypeRef? {
        guard let a, let b else { return nil }
        if let r = param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray) { return r }
        guard CFGetTypeID(a) == AXTextMarkerGetTypeID(), CFGetTypeID(b) == AXTextMarkerGetTypeID() else { return nil }
        let ia = param(el, "AXIndexForTextMarker", a) as? Int ?? 0
        let ib = param(el, "AXIndexForTextMarker", b) as? Int ?? 0
        return ia <= ib ? AXTextMarkerRangeCreate(nil, a as! AXTextMarker, b as! AXTextMarker)
                        : AXTextMarkerRangeCreate(nil, b as! AXTextMarker, a as! AXTextMarker)
    }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }

    static func parent(_ el: AXUIElement) -> AXUIElement? { element(el, kAXParentAttribute) }

    static func attributeNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func parameterizedNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// The nearest AXWebArea at or above `el`, where WebKit and Chromium expose text markers.
    static func webArea(from el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        var hops = 0
        while let c = cur, hops < 40 {
            if role(c) == "AXWebArea" { return c }
            cur = parent(c)
            hops += 1
        }
        return nil
    }

    /// Global mouse location in Accessibility coordinates (origin top-left of the primary display).
    static func mouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { let t = trimmed; return t.isEmpty ? nil : t }
}
