// Bridge.swift — the print engine, in pure Swift (no Python, no dependencies).
//
// Reimplements the reverse-engineered UPS local print protocol (see
// research/PROTOCOL.md): a tiny HTTP server on 127.0.0.1:4349 that
//   - GET /listPrinters (navigation)  -> serves the handshake HTML page
//   - GET /listPrinters (fetch/XHR)   -> returns the printer list as JSON
//   - POST /print                     -> Base64-decodes the label and prints via `lp`
//   - POST /probe                     -> diagnostics sink (logged)
//   - GET /ping                       -> liveness
// The handshake page asks ups.com (window.opener) for the CURRENT label via
// postMessage; ups.com posts the base64 ZPL back; the page POSTs it to /print.

import Foundation

// MARK: - Configuration / shared state

final class BridgeConfig {
    static let shared = BridgeConfig()
    let port: UInt16 = 4349
    private let defaults = UserDefaults.standard

    var printer: String {
        get { defaults.string(forKey: "printer") ?? "" }
        set { defaults.set(newValue, forKey: "printer") }
    }
    var labelType: String {
        get { defaults.string(forKey: "labelType") ?? "zpl" }
        set { defaults.set(newValue, forKey: "labelType") }
    }
}

// Simple file + memory logger (so the UI and `tail` can both see activity).
final class BridgeLog {
    static let shared = BridgeLog()
    private let path: String
    private let q = DispatchQueue(label: "bridge.log")
    private(set) var lines: [String] = []
    var onLine: ((String) -> Void)?

    init() {
        let logs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        path = (logs as NSString).appendingPathComponent("ups-print-bridge.log")
    }
    func log(_ msg: String) {
        let df = ISO8601DateFormatter()
        let line = df.string(from: Date()) + "  " + msg
        q.async {
            self.lines.append(line)
            if self.lines.count > 500 { self.lines.removeFirst(self.lines.count - 500) }
            if let data = (line + "\n").data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: self.path) {
                    fh.seekToEndOfFile(); fh.write(data); try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: self.path))
                }
            }
            DispatchQueue.main.async { self.onLine?(line) }
        }
    }
}

// MARK: - Printers (CUPS via lp / lpstat)

enum Printers {
    /// CUPS queue names. Uses `lpstat -e` (enumerates destinations, one name per
    /// line) which is locale-independent — unlike `lpstat -p`, whose text is
    /// translated (e.g. "la impresora X está inactiva" in Spanish).
    static func list() -> [String] {
        let out = run("/usr/bin/lpstat", ["-e"])
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Print raw bytes to a CUPS queue by piping them to `lp` via stdin.
    /// No temp file (robust, nothing left behind). Success = lp exit code 0.
    @discardableResult
    static func send(_ data: Data, to printer: String) -> (Bool, String) {
        // debug copy of the last printed label
        let last = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/ups-last-label.zpl")
        try? data.write(to: URL(fileURLWithPath: last))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lp")
        p.arguments = ["-d", printer]
        let stdin = Pipe(), output = Pipe()
        p.standardInput = stdin
        p.standardOutput = output; p.standardError = output
        do { try p.run() } catch { return (false, "exec error: \(error)") }
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let ok = (p.terminationStatus == 0)
        BridgeLog.shared.log("PRINT lp -d \(printer) (\(data.count) bytes) rc=\(p.terminationStatus) -> \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        return (ok, out)
    }

    /// Run a process, returning its combined output (ignoring exit code).
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> String {
        return runStatus(launchPath, args).1
    }

    /// Run a process, returning (exitCode, combinedOutput).
    static func runStatus(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "exec error: \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
