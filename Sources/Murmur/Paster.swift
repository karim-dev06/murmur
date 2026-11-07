import AppKit
import ApplicationServices

/// Types text into whatever field has focus, by pasting, then puts the old clipboard back.
@MainActor
final class Paster {
    enum Result { case pasted, copied }

    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func insert(_ text: String) async -> Result {
        let focused = Self.focusedElement()
        let editable = focused.map(Self.isEditable) ?? false
        var payload = text
        if let focused, editable, Self.needsLeadingSpace(focused, before: text) { payload = " " + text }

        let pasteboard = NSPasteboard.general
        // Only borrow the clipboard when we know there is a text field. Otherwise leave the words on it.
        let saved = editable ? Self.snapshot(pasteboard) : nil
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        if editable { pasteboard.setData(Data(), forType: Self.transient) }
        let stamp = pasteboard.changeCount

        Self.pressCommandV()

        guard let saved else { return .copied }
        try? await Task.sleep(for: .milliseconds(700))
        if pasteboard.changeCount == stamp { Self.restore(saved, to: pasteboard) }
        return .pasted
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        guard let value = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role = attribute(element, kAXRoleAttribute) as? String, textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    /// Adds a space when the cursor sits right after a word, so dictations don't run together.
    private static func needsLeadingSpace(_ element: AXUIElement, before text: String) -> Bool {
        guard let first = text.first, !first.isPunctuation,
              let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location > 0 else { return false }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return false }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
              let string = out as? String, let character = string.last else { return false }
        return !character.isWhitespace && !"([{\"'/-".contains(character)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    // MARK: - Clipboard and keys

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ items: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
