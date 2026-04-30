import AppKit
import ApplicationServices
import Foundation

// MARK: - Report

struct StepResult: Codable {
    let name: String
    let ok: Bool
    let detail: String
    let elapsedMs: Int
}

struct ScenarioReport: Codable {
    let scenario: String
    let startedAt: String
    let finishedAt: String
    let steps: [StepResult]
    let overall: Bool
    let screenshotPath: String?
    let logTailPath: String?
}

final class Reporter {
    private var steps: [StepResult] = []
    private let start = Date()
    private let name: String
    private let outputDir: URL

    init(scenario: String, outputDir: URL) {
        self.name = scenario
        self.outputDir = outputDir
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    func step(_ name: String, _ work: () throws -> String) {
        let t0 = Date()
        do {
            let detail = try work()
            steps.append(.init(name: name, ok: true, detail: detail, elapsedMs: Int(Date().timeIntervalSince(t0) * 1000)))
            fputs("✓ \(name) — \(detail)\n", stdout)
        } catch {
            steps.append(.init(name: name, ok: false, detail: "\(error)", elapsedMs: Int(Date().timeIntervalSince(t0) * 1000)))
            fputs("✗ \(name) — \(error)\n", stderr)
        }
    }

    func flush(screenshot: String?, logTail: String?) -> ScenarioReport {
        let f = ISO8601DateFormatter()
        let report = ScenarioReport(
            scenario: name,
            startedAt: f.string(from: start),
            finishedAt: f.string(from: Date()),
            steps: steps,
            overall: steps.allSatisfy { $0.ok },
            screenshotPath: screenshot,
            logTailPath: logTail
        )
        let filename = "\(Int(start.timeIntervalSince1970))-\(name).json"
        let out = outputDir.appendingPathComponent(filename)
        let data = try! JSONEncoder.pretty.encode(report)
        try? data.write(to: out)
        fputs("→ report: \(out.path)\n", stdout)
        return report
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - Errors

enum HarnessError: LocalizedError {
    case notTrusted
    case appNotRunning(String)
    case panelNotFound
    case elementNotFound(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Accessibility permission not granted to harness binary"
        case let .appNotRunning(name): return "\(name) not running"
        case .panelNotFound: return "LittleAI floating panel not found (AXWindow)"
        case let .elementNotFound(what): return "Element not found: \(what)"
        case let .timeout(what): return "Timeout waiting for: \(what)"
        }
    }
}

// MARK: - AX helpers

enum AX {
    static func app(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func ensureRunning(bundleID: String, launchPath: String? = nil) throws -> NSRunningApplication {
        if let app = app(bundleID: bundleID) { return app }
        let url: URL
        if let p = launchPath { url = URL(fileURLWithPath: p) }
        else if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { url = u }
        else { throw HarnessError.appNotRunning(bundleID) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let sem = DispatchSemaphore(value: 0)
        var opened: NSRunningApplication?
        var opError: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { running, error in
            opened = running
            opError = error
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        if let e = opError { throw e }
        guard let o = opened else { throw HarnessError.appNotRunning(bundleID) }
        // Let the app's event loop spin up before we poke at it.
        usleep(800_000)
        return o
    }

    static func activate(_ app: NSRunningApplication) {
        app.activate()
        usleep(250_000)
    }

    /// Blocks until `bundleID` is the frontmost app, or timeout expires. Cocoa's
    /// activation API is "best effort" — if some unrelated dialog is stealing focus we
    /// want to fail loudly rather than ship events to the wrong app.
    static func waitFrontmost(bundleID: String, timeout: TimeInterval = 3.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                return
            }
            usleep(100_000)
        }
        throw HarnessError.timeout("\(bundleID) to become frontmost")
    }

    static func terminate(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        // Give Cocoa time to tear down windows before re-launch.
        usleep(500_000)
    }

    /// Retries a block until it returns non-nil or timeout expires.
    static func wait<T>(_ name: String, timeout: TimeInterval = 4.0, step: TimeInterval = 0.1, _ probe: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = probe() { return r }
            usleep(useconds_t(step * 1_000_000))
        }
        throw HarnessError.timeout(name)
    }

    static func attr<T>(_ el: AXUIElement, _ key: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as [AXUIElement]?) ?? []
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        return (attr(appEl, kAXWindowsAttribute as String) as [AXUIElement]?) ?? []
    }

    /// Depth-first walk; returns the first element that matches `predicate`.
    static func firstDescendant(_ root: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack: [AXUIElement] = [root]
        var visited = 0
        while let el = stack.popLast(), visited < 500 {
            visited += 1
            if predicate(el) { return el }
            stack.append(contentsOf: children(el))
        }
        return nil
    }

    static func describe(_ el: AXUIElement) -> String {
        let role: String = attr(el, kAXRoleAttribute as String) ?? "?"
        let title: String = attr(el, kAXTitleAttribute as String) ?? ""
        let label: String = attr(el, kAXDescriptionAttribute as String) ?? ""
        return "\(role)[title=\(title) desc=\(label)]"
    }

    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    static func setValue(_ el: AXUIElement, _ value: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success
    }
}

// MARK: - Keyboard / typing simulation

enum Key {
    static func postShiftTap() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Emit flagsChanged down + up for Left Shift (keycode 0x38). Hotkey listens on
        // CGEventType.flagsChanged and filters by .maskShift; it does NOT require a real
        // keyDown, so a flagsChanged pair is enough to register a "shift tap".
        let down = CGEvent(source: src)
        down?.type = .flagsChanged
        down?.setIntegerValueField(.keyboardEventKeycode, value: 0x38)
        down?.flags = [.maskShift]
        down?.post(tap: .cghidEventTap)
        usleep(5_000)
        let up = CGEvent(source: src)
        up?.type = .flagsChanged
        up?.setIntegerValueField(.keyboardEventKeycode, value: 0x38)
        up?.flags = []
        up?.post(tap: .cghidEventTap)
    }

    static func postDoubleShift() {
        postShiftTap()
        usleep(150_000) // 150 ms — well inside the 400ms window the Hotkey class uses
        postShiftTap()
    }

    static func postCmd(_ keyCode: CGKeyCode) {
        postKey(keyCode, flags: .maskCommand)
    }

    static func postEscape() {
        postKey(0x35)
    }

    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func postString(_ s: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for char in s.unicodeScalars {
            var utf16 = [UniChar](repeating: 0, count: 2)
            let len = (String(char)).utf16.count
            let downEvt = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let upEvt = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            var units = Array(String(char).utf16)
            if units.count > 2 { units = Array(units.prefix(2)) }
            utf16.replaceSubrange(0..<units.count, with: units)
            utf16.withUnsafeBufferPointer { buf in
                downEvt?.keyboardSetUnicodeString(stringLength: len, unicodeString: buf.baseAddress)
                upEvt?.keyboardSetUnicodeString(stringLength: len, unicodeString: buf.baseAddress)
            }
            downEvt?.post(tap: .cghidEventTap)
            upEvt?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }
}

// MARK: - Screenshot

enum Shot {
    /// Uses /usr/sbin/screencapture — the system tool — rather than
    /// CGDisplayCreateImage which Apple deprecated in 14 and is locked behind
    /// a screen-recording entitlement that we don't want to chase in a harness.
    static func take(to path: String) -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/sbin/screencapture"
        proc.arguments = ["-x", path]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch { return false }
    }
}

// MARK: - Log capture

enum LogCap {
    static let defaultPath = "\(NSHomeDirectory())/Library/Logs/LittleAI/littleai.log"

    static func mark() -> UInt64 {
        let url = URL(fileURLWithPath: defaultPath)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 {
            return size
        }
        return 0
    }

    /// Returns the bytes appended to littleai.log since `mark`, written to a tail file.
    static func sliceSince(_ mark: UInt64, to outPath: String) -> String? {
        let url = URL(fileURLWithPath: defaultPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: mark)
            let data = handle.availableData
            try data.write(to: URL(fileURLWithPath: outPath))
            return outPath
        } catch {
            return nil
        }
    }
}

// MARK: - Scenarios

let littleAIBundle = "ai.little.LittleAI"
let textEditBundle = "com.apple.TextEdit"

let reportsDir = URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/tools/reports")

func scenarioSmokeCorrect() -> ScenarioReport {
    let r = Reporter(scenario: "smoke-correct", outputDir: reportsDir)
    let logMark = LogCap.mark()

    r.step("trusted") {
        guard AXIsProcessTrusted() else { throw HarnessError.notTrusted }
        return "AX granted"
    }
    var littleAI: NSRunningApplication?
    r.step("launch LittleAI") { () -> String in
        let app = try AX.ensureRunning(bundleID: littleAIBundle, launchPath: "/Applications/LittleAI.app")
        littleAI = app
        return "pid=\(app.processIdentifier)"
    }
    r.step("launch TextEdit") { () -> String in
        // Kill any prior instance: TextEdit's restore-windows + file-open-dialog behaviour
        // can push Finder to frontmost and steal our subsequent keystrokes. A clean launch
        // opens an empty document with TextEdit itself in front.
        AX.terminate(bundleID: textEditBundle)
        let app = try AX.ensureRunning(bundleID: textEditBundle)
        AX.activate(app)
        try AX.waitFrontmost(bundleID: textEditBundle)
        // New blank document. Do it after we're sure TextEdit is frontmost so the ⌘N
        // lands on the right app and not on whatever dialog was stealing focus.
        Key.postCmd(0x2D) // N
        usleep(500_000)
        try AX.waitFrontmost(bundleID: textEditBundle)
        return "pid=\(app.processIdentifier)"
    }
    r.step("type sample text with typos") {
        try AX.waitFrontmost(bundleID: textEditBundle)
        Key.postString("Questa è una frase con erori grammaticali da corregere.")
        usleep(400_000)
        return "typed"
    }
    r.step("select all") {
        Key.postCmd(0x00) // A
        usleep(200_000)
        return "⌘A"
    }
    r.step("trigger hotkey (double-shift)") {
        Key.postDoubleShift()
        return "double-shift emitted"
    }
    r.step("find LittleAI floating panel") { () -> String in
        guard let la = littleAI else { throw HarnessError.appNotRunning("LittleAI") }
        let panel = try AX.wait("LittleAI AXWindow", timeout: 4.0) { () -> AXUIElement? in
            AX.windows(of: la).first
        }
        return AX.describe(panel)
    }
    r.step("find Correggi button") { () -> String in
        guard let la = littleAI else { throw HarnessError.appNotRunning("LittleAI") }
        let panel = AX.windows(of: la).first!
        let btn = AX.firstDescendant(panel) { el in
            let role: String = AX.attr(el, kAXRoleAttribute as String) ?? ""
            if role != "AXButton" { return false }
            let desc: String = AX.attr(el, kAXDescriptionAttribute as String) ?? ""
            let title: String = AX.attr(el, kAXTitleAttribute as String) ?? ""
            return desc.contains("Correggi") || title.contains("Correggi")
        }
        guard let btn else { throw HarnessError.elementNotFound("AXButton Correggi") }
        return AX.describe(btn)
    }

    let shotPath = reportsDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-smoke-correct.png").path
    _ = Shot.take(to: shotPath)
    let logOut = reportsDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-smoke-correct.log").path
    let logPath = LogCap.sliceSince(logMark, to: logOut)

    return r.flush(screenshot: shotPath, logTail: logPath)
}

// MARK: - Main

// NSApplication is required to let Cocoa frameworks set up their run-loop machinery
// (NSWorkspace.openApplication posts Notifications from the main thread). We don't run
// the event loop — everything is synchronous-with-polling.
_ = NSApplication.shared

let trusted = AXIsProcessTrusted()
if !trusted {
    fputs("WARN: AX permission not granted to harness binary — some steps will fail.\n", stderr)
    fputs("Grant via Settings → Privacy & Security → Accessibility and re-run.\n", stderr)
}

let report = scenarioSmokeCorrect()
fputs("\noverall=\(report.overall ? "PASS" : "FAIL")\n", stdout)
exit(report.overall ? 0 : 1)
