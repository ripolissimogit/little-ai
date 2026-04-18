import AppKit
import CoreGraphics

/// Detects a double-tap of the Shift modifier within a 400ms window.
///
/// Any key press between the two Shift presses resets the state, so ordinary
/// capitalization (Shift + letter) does not trigger.
final class DoubleShiftDetector {
    var onTrigger: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastShiftDown: CFAbsoluteTime = 0
    private var shiftWasDown = false
    private let window: CFTimeInterval = 0.4

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userData in
                guard let userData else { return Unmanaged.passUnretained(event) }
                let detector = Unmanaged<DoubleShiftDetector>.fromOpaque(userData).takeUnretainedValue()
                detector.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            lastShiftDown = 0
            shiftWasDown = false
        case .flagsChanged:
            let isShiftDown = event.flags.contains(.maskShift)
            if isShiftDown && !shiftWasDown {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastShiftDown <= window {
                    lastShiftDown = 0
                    DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
                } else {
                    lastShiftDown = now
                }
            }
            shiftWasDown = isShiftDown
        default:
            break
        }
    }
}
