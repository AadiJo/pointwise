import AppKit
import CoreGraphics

/// Watches the keyboard system-wide with a listen-only event tap:
/// hold Control+Option to talk, double-tap Control to type, Escape to stop.
/// Needs Accessibility (or Input Monitoring) permission.
@MainActor
final class HotkeyMonitor {
    var onPushToTalkPressed: (() -> Void)?
    var onPushToTalkReleased: (() -> Void)?
    /// Control+Option plus another key: someone else's shortcut, so stop listening without asking.
    var onPushToTalkCancelled: (() -> Void)?
    var onControlDoubleTapped: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPushToTalkHeld = false
    private var isPushToTalkCancelledByChord = false
    private var controlPressedAt: Date?
    private var lastControlTapAt: Date?
    private var controlTapWasSpoiled = false

    private static let doubleTapWindowSeconds: TimeInterval = 0.4
    private static let maximumTapHoldSeconds: TimeInterval = 0.35
    private static let escapeKeyCode: Int64 = 53

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let eventMask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            MainActor.assumeIsolated {
                monitor.handle(eventType: eventType, keyCode: keyCode, flags: flags)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
        runLoopSource = nil
        isPushToTalkHeld = false
    }

    private func handle(eventType: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        case .flagsChanged:
            handleModifierChange(flags: flags)
        case .keyDown:
            controlTapWasSpoiled = true
            if isPushToTalkHeld && !isPushToTalkCancelledByChord {
                isPushToTalkCancelledByChord = true
                onPushToTalkCancelled?()
            }
            if keyCode == Self.escapeKeyCode { onEscapePressed?() }
        default:
            break
        }
    }

    private func handleModifierChange(flags: CGEventFlags) {
        let isControlDown = flags.contains(.maskControl)
        let isOptionDown = flags.contains(.maskAlternate)
        let hasOtherModifiers = flags.contains(.maskCommand) || flags.contains(.maskShift)

        let shouldHoldPushToTalk = isControlDown && isOptionDown && !hasOtherModifiers
        if shouldHoldPushToTalk && !isPushToTalkHeld {
            isPushToTalkHeld = true
            isPushToTalkCancelledByChord = false
            controlTapWasSpoiled = true
            onPushToTalkPressed?()
        } else if !shouldHoldPushToTalk && isPushToTalkHeld {
            isPushToTalkHeld = false
            if !isPushToTalkCancelledByChord { onPushToTalkReleased?() }
        }

        // Double-tap Control: two quick, clean taps of Control alone.
        if isControlDown && !isOptionDown && !hasOtherModifiers && controlPressedAt == nil {
            controlPressedAt = Date()
            controlTapWasSpoiled = false
        } else if isControlDown && (isOptionDown || hasOtherModifiers) {
            controlTapWasSpoiled = true
        } else if !isControlDown, let controlPressedAt {
            self.controlPressedAt = nil
            let wasCleanTap = !controlTapWasSpoiled && Date().timeIntervalSince(controlPressedAt) < Self.maximumTapHoldSeconds
            guard wasCleanTap else {
                lastControlTapAt = nil
                return
            }
            if let lastControlTapAt, Date().timeIntervalSince(lastControlTapAt) < Self.doubleTapWindowSeconds {
                self.lastControlTapAt = nil
                onControlDoubleTapped?()
            } else {
                lastControlTapAt = Date()
            }
        }
    }
}

/// Reports left clicks anywhere on screen. Mouse monitoring does not need
/// Accessibility permission, so walkthroughs work as soon as Pointwise runs.
@MainActor
final class GlobalClickMonitor {
    var onClick: ((CGPoint) -> Void)?
    private var globalMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.onClick?(clickLocation) }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
    }
}

/// Performs "show me by doing it" actions. The real Mac uses CGEvents.
@MainActor
protocol ComputerActionPerformer: AnyObject {
    var canPerformActions: Bool { get }
    func click(at globalPoint: CGPoint, clickCount: Int) async
    func type(_ text: String) async
    func pressKeys(_ keyCombination: String) async
    func scroll(at globalPoint: CGPoint, lines: Int) async
}

@MainActor
final class SystemActionPerformer: ComputerActionPerformer {
    var canPerformActions: Bool { AXIsProcessTrusted() }

    /// CGEvents use a top-left origin on the main display.
    private func quartzPoint(fromGlobal globalPoint: CGPoint) -> CGPoint {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: globalPoint.x, y: mainDisplayHeight - globalPoint.y)
    }

    func click(at globalPoint: CGPoint, clickCount: Int) async {
        let location = quartzPoint(fromGlobal: globalPoint)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 60_000_000)
        for clickNumber in 1...max(1, clickCount) {
            let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)
            let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
            downEvent?.post(tap: .cghidEventTap)
            upEvent?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func type(_ text: String) async {
        for character in text {
            let utf16Characters = Array(String(character).utf16)
            let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            downEvent?.keyboardSetUnicodeString(stringLength: utf16Characters.count, unicodeString: utf16Characters)
            upEvent?.keyboardSetUnicodeString(stringLength: utf16Characters.count, unicodeString: utf16Characters)
            downEvent?.post(tap: .cghidEventTap)
            upEvent?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 18_000_000)
        }
    }

    func pressKeys(_ keyCombination: String) async {
        guard let parsedCombination = KeyCombination(parsing: keyCombination) else { return }
        let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: parsedCombination.keyCode, keyDown: true)
        let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: parsedCombination.keyCode, keyDown: false)
        downEvent?.flags = parsedCombination.flags
        upEvent?.flags = parsedCombination.flags
        downEvent?.post(tap: .cghidEventTap)
        upEvent?.post(tap: .cghidEventTap)
    }

    func scroll(at globalPoint: CGPoint, lines: Int) async {
        let location = quartzPoint(fromGlobal: globalPoint)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-lines), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }
}

/// Parses strings such as "cmd+shift+t" or "return" into a key code and modifiers.
struct KeyCombination {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46, ".": 47, ",": 43, "/": 44,
    ]

    init?(parsing keyCombination: String) {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        for rawPart in keyCombination.lowercased().split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: keyCode = Self.namedKeyCodes[part]
            }
        }
        guard let keyCode else { return nil }
        self.keyCode = keyCode
        self.flags = flags
    }
}
