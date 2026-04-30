import AppKit

/// Detects a double-tap of Shift within ~400 ms via NSEvent monitors. Resets the pending
/// tap state on any other key, mouse click or scroll so ordinary capitalization
/// (Shift + letter) doesn't fire.
///
/// We use two monitors:
///   - `addGlobalMonitorForEvents` receives events headed to other apps (the common case
///     while LittleAI sits in the menu bar).
///   - `addLocalMonitorForEvents` receives events headed to LittleAI itself — for example
///     while the toolbar panel is key, otherwise the second Shift would be missed.
///
/// Same permission requirement as the older `CGEventTap` (Accessibility), but the
/// NSEvent monitors aren't subject to the silent `tapDisabledByTimeout`/
/// `tapDisabledByUserInput` failure mode that left the previous implementation deaf
/// after sleep/wake or secure-input transitions.
final class Hotkey {
    var onTrigger: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let window: CFTimeInterval = 0.4

    /// Timestamp of an unmatched shift-down edge — i.e. shift is currently held and we
    /// haven't seen its release yet. Cleared by the matching release or by any
    /// non-shift event ("user is doing something else, abort detection").
    private var pendingDownAt: CFAbsoluteTime?
    /// Timestamp of the release of a tapped shift (down→up within `window`, with no other
    /// key/mouse/scroll in between). Set when we're armed for a possible second tap;
    /// cleared on the second tap, on timeout, or on any other event.
    private var armedAt: CFAbsoluteTime?
    /// Mirror of the physical shift state across consecutive flagsChanged events. NSEvent
    /// reports the post-event flag mask, not the direction of the transition, so we
    /// derive edges by comparing against this remembered state.
    private var shiftWasDown = false

    func start() {
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel,
        ]
        Log.info("hotkey installing NSEvent monitors", tag: "hk")
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        if globalMonitor == nil {
            Log.error("addGlobalMonitorForEvents returned nil — accessibility permission missing?", tag: "hk")
        }
        Log.info("hotkey ready (window=\(window)s, monitors: global=\(globalMonitor != nil) local=\(localMonitor != nil))", tag: "hk")
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(isDown: event.modifierFlags.contains(.shift))
        default:
            // Any other key, mouse click or scroll counts as "user did something else" and
            // wipes the in-progress tap detection. Without this, shift+letter or shift+click
            // could arm armedAt and leak into the next real tap detection.
            handleInterrupt()
        }
    }

    private func handleFlagsChanged(isDown: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if isDown && !shiftWasDown {
            // Shift down edge.
            if let armed = armedAt, now - armed <= window {
                let delta = now - armed
                Log.debug("double-shift detected (Δ=\(String(format: "%.3f", delta))s)", tag: "hk")
                armedAt = nil
                pendingDownAt = nil
                shiftWasDown = true
                DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
                return
            }
            pendingDownAt = now
            armedAt = nil
        } else if !isDown && shiftWasDown {
            // Shift up edge: only count it as a "tap" (=> arm) if shift was held briefly.
            // A long hold (e.g. typing several capitalised words) shouldn't arm.
            if let down = pendingDownAt, now - down <= window {
                armedAt = now
            } else {
                armedAt = nil
            }
            pendingDownAt = nil
        }
        shiftWasDown = isDown
    }

    private func handleInterrupt() {
        pendingDownAt = nil
        armedAt = nil
    }
}
