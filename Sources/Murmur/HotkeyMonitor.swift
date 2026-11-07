import AppKit

/// Watches the keyboard for the talk key, Esc and ⌥⌘V. Needs Accessibility permission.
@MainActor
final class HotkeyMonitor {
    enum Trigger { case fn, rightOption }

    var trigger: Trigger = .fn
    var onTriggerDown: () -> Void = {}
    var onTriggerUp: () -> Void = {}
    var onOtherKeyWhileHeld: () -> Void = {}
    var isRecording: () -> Bool = { false }
    var onEscape: () -> Void = {}
    var onPasteLast: () -> Void = {}

    private var tap: CFMachPort?
    private var triggerHeld = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let down: Bool
            switch trigger {
            case .fn: down = event.flags.contains(.maskSecondaryFn)
            case .rightOption: down = event.flags.rawValue & 0x40 != 0 // device bit for the right Option key
            }
            if down, !triggerHeld {
                triggerHeld = true
                onTriggerDown()
            } else if !down, triggerHeld {
                triggerHeld = false
                onTriggerUp()
            }

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            if code == 53, isRecording() {
                onEscape()
                return nil
            }
            if code == 9, flags.contains(.maskCommand), flags.contains(.maskAlternate), !flags.contains(.maskControl), !flags.contains(.maskShift) {
                onPasteLast()
                return nil
            }
            if triggerHeld { onOtherKeyWhileHeld() }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { monitor.handle(type, event) }
}
