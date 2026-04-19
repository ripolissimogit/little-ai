import AppKit
import CoreGraphics

/// Detects a double-tap of Shift within 400ms. Any intervening key press resets the state
/// so ordinary capitalization (Shift + letter) doesn't fire.
final class Hotkey {
    var onTrigger: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastDown: CFAbsoluteTime = 0
    private var shiftWasDown = false
    private let window: CFTimeInterval = 0.4

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        Log.info("hotkey start installing CGEventTap", tag: "hk")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userData in
                if let userData {
                    let h = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
                    h.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: ptr
        ) else {
            Log.error("CGEvent.tapCreate returned nil — accessibility permission missing?", tag: "hk")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
        Log.info("hotkey ready (listening for double-shift, window=\(window)s)", tag: "hk")
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            lastDown = 0
            shiftWasDown = false
        case .flagsChanged:
            let isDown = event.flags.contains(.maskShift)
            if isDown && !shiftWasDown {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastDown <= window {
                    lastDown = 0
                    Log.debug("double-shift detected (Δ=\(String(format: "%.3f", now - lastDown))s)", tag: "hk")
                    DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
                } else {
                    lastDown = now
                }
            }
            shiftWasDown = isDown
        default: break
        }
    }
}
