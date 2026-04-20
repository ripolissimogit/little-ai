import Foundation

/// File-backed logger with optional Axiom sink. Writes every line to
/// `~/Library/Logs/LittleAI/littleai.log` and mirrors to stderr. The Axiom sink batches
/// events and flushes on a timer or when the buffer fills.
enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO "
        case warn  = "WARN "
        case error = "ERROR"
    }

    static let fileURL: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LittleAI", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("littleai.log")
    }()

    private static let queue = DispatchQueue(label: "ai.little.LittleAI.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static var handle: FileHandle? = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: fileURL)
        _ = try? h?.seekToEnd()
        return h
    }()

    static func boot(version: String) {
        Axiom.start()
        info("=== LittleAI boot v\(version) pid=\(ProcessInfo.processInfo.processIdentifier) ===", tag: "app")
        info("log file: \(fileURL.path)", tag: "app")
        if Secrets.axiomToken != nil {
            info("axiom sink enabled dataset=\(Secrets.axiomDataset)", tag: "app")
        } else {
            info("axiom sink disabled (no token in Keychain)", tag: "app")
        }
    }

    static func debug(_ message: @autoclosure () -> String, tag: String = "app") { write(.debug, tag, message()) }
    static func info (_ message: @autoclosure () -> String, tag: String = "app") { write(.info,  tag, message()) }
    static func warn (_ message: @autoclosure () -> String, tag: String = "app") { write(.warn,  tag, message()) }
    static func error(_ message: @autoclosure () -> String, tag: String = "app") { write(.error, tag, message()) }

    private static func write(_ level: Level, _ tag: String, _ message: String) {
        let now = Date()
        let line = "\(formatter.string(from: now)) \(level.rawValue) [\(tag)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
                FileHandle.standardError.write(data)
            }
        }
        Axiom.push([
            "_time": iso.string(from: now),
            "level": level.rawValue.trimmingCharacters(in: .whitespaces),
            "tag": tag,
            "message": message,
            "pid": ProcessInfo.processInfo.processIdentifier
        ])
    }
}

/// Axiom.co ingest sink. Buffers events and POSTs batches. Silent on transport errors
/// (writes to stderr, not to Log, to avoid feedback loops). Disabled when no token is
/// stored in the Keychain — users who don't want remote telemetry simply leave the
/// Axiom fields empty in Settings.
enum Axiom {
    private static func endpoint() -> URL? {
        guard Secrets.axiomToken != nil else { return nil }
        return URL(string: "https://api.axiom.co/v1/datasets/\(Secrets.axiomDataset)/ingest")
    }
    private static let queue = DispatchQueue(label: "ai.little.LittleAI.axiom")
    private static var buffer: [[String: Any]] = []
    private static var timer: DispatchSourceTimer?
    private static let maxBufferSize = 500
    private static let batchSize = 50
    private static let flushInterval: TimeInterval = 2.0

    static func start() {
        queue.async {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
            t.setEventHandler { flushLocked() }
            t.resume()
            timer = t
        }
    }

    static func push(_ event: [String: Any]) {
        queue.async {
            if buffer.count >= maxBufferSize {
                buffer.removeFirst(buffer.count - maxBufferSize + 1)
            }
            buffer.append(event)
            if buffer.count >= batchSize {
                flushLocked()
            }
        }
    }

    private static func flushLocked() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        send(batch)
    }

    private static func send(_ events: [[String: Any]]) {
        guard let url = endpoint(), let token = Secrets.axiomToken else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err {
                FileHandle.standardError.write(Data("axiom error: \(err.localizedDescription)\n".utf8))
                return
            }
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                FileHandle.standardError.write(Data("axiom HTTP \(http.statusCode): \(body.prefix(200))\n".utf8))
            }
        }.resume()
    }
}
