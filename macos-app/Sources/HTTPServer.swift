// HTTPServer.swift — a tiny localhost HTTP/1.1 server (POSIX sockets) that
// speaks the UPS print protocol. Each connection is handled on a background
// queue, answered, and closed (Connection: close).

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ZPL extraction (mirror of the Python bridge)

enum ZPL {
    static func looksLikeZPL(_ d: Data) -> Bool {
        d.range(of: Data("^XA".utf8)) != nil
    }

    static func decodeBase64(_ s: String) -> Data? {
        let cleaned = s.filter { !$0.isWhitespace }
        guard cleaned.count >= 8 else { return nil }
        let pad = (4 - cleaned.count % 4) % 4
        let padded = cleaned + String(repeating: "=", count: pad)
        return Data(base64Encoded: padded)
    }

    /// Pull printable ZPL bytes out of an arbitrary value (raw ^XA…, or base64).
    static func fromValue(_ v: String) -> Data? {
        if v.contains("^XA") { return v.data(using: .utf8) }
        if let d = decodeBase64(v), looksLikeZPL(d) { return d }
        return nil
    }

    /// Extract ZPL from a request body (form-encoded / JSON / base64 / raw).
    static func extract(body: Data, contentType: String) -> Data? {
        guard let text = String(data: body, encoding: .utf8) else {
            return looksLikeZPL(body) ? body : nil
        }
        let ct = contentType.lowercased()
        // form-encoded: printerName=...&labelBytes=<urlencoded base64>
        if text.contains("="), text.contains("&") || ct.contains("urlencoded") {
            for pair in text.split(separator: "&") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let val = String(pair[pair.index(after: eq)...])
                let decoded = val.removingPercentEncoding ?? val
                if let z = fromValue(decoded) { return z }
            }
        }
        // JSON: scan recursively for a ^XA / base64 string
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let obj = try? JSONSerialization.jsonObject(with: body),
               let z = findInJSON(obj) { return z }
        }
        if text.contains("^XA") { return text.data(using: .utf8) }
        if let d = decodeBase64(text), looksLikeZPL(d) { return d }
        return looksLikeZPL(body) ? body : nil
    }

    private static func findInJSON(_ obj: Any) -> Data? {
        var stack: [Any] = [obj]
        while let cur = stack.popLast() {
            if let dict = cur as? [String: Any] { stack.append(contentsOf: dict.values) }
            else if let arr = cur as? [Any] { stack.append(contentsOf: arr) }
            else if let s = cur as? String, let z = fromValue(s) { return z }
        }
        return nil
    }
}

// MARK: - HTTP request/response

struct HTTPRequest {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body = Data()
    var isNavigation: Bool {
        (headers["sec-fetch-dest"] == "document") || (headers["accept"]?.contains("text/html") ?? false)
    }
}

// MARK: - Server

final class HTTPServer {
    private let port: UInt16
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "bridge.http", attributes: .concurrent)
    private var running = false
    private var lastPrintSig: String = ""
    private var lastPrintAt: Date = .distantPast
    private let dedupeWindow: TimeInterval = 5
    private let printLock = NSLock()
    var onActivity: (() -> Void)?

    init(port: UInt16) { self.port = port }

    /// Start listening. Returns false if the port is already bound (another instance).
    @discardableResult
    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // localhost only
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); return false }
        guard listen(fd, 16) == 0 else { close(fd); return false }
        listenFD = fd
        running = true
        BridgeLog.shared.log("UPS Print Bridge listening on 127.0.0.1:\(port)")
        queue.async { [weak self] in self?.acceptLoop() }
        return true
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if running { usleep(10_000); continue } else { break } }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    // Read the full request (headers + body by Content-Length) and route it.
    private func handle(_ fd: Int32) {
        defer { close(fd) }
        guard var req = readRequest(fd) else { return }
        DispatchQueue.main.async { self.onActivity?() }
        route(&req, fd)
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        let chunk = 8192
        var tmp = [UInt8](repeating: 0, count: chunk)
        // read until end of headers
        var headerEnd: Range<Data.Index>? = nil
        while headerEnd == nil {
            let n = read(fd, &tmp, chunk)
            if n <= 0 { return nil }
            buffer.append(contentsOf: tmp[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 8_000_000 { return nil }
        }
        guard let he = headerEnd,
              let headerStr = String(data: buffer[..<he.lowerBound], encoding: .utf8) else { return nil }
        var req = HTTPRequest()
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let rl = requestLine.split(separator: " ")
        if rl.count >= 2 {
            req.method = String(rl[0]).uppercased()
            let target = String(rl[1])
            if let q = target.firstIndex(of: "?") {
                req.path = String(target[..<q])
                req.query = parseQuery(String(target[target.index(after: q)...]))
            } else {
                req.path = target
            }
        }
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }
        // body
        var body = Data(buffer[he.upperBound...])
        if let lenStr = req.headers["content-length"], let len = Int(lenStr) {
            while body.count < len {
                let n = read(fd, &tmp, chunk)
                if n <= 0 { break }
                body.append(contentsOf: tmp[0..<n])
            }
        }
        req.body = body
        return req
    }

    private func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[k] = v
        }
        return out
    }

    // MARK: routing

    private func route(_ req: inout HTTPRequest, _ fd: Int32) {
        let path = req.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let origin = req.headers["origin"] ?? "*"

        if req.method == "OPTIONS" { send(fd, status: 204, origin: origin); return }
        if path.hasSuffix("favicon.ico") { send(fd, status: 204, origin: origin); return }

        if req.method == "GET" {
            if path.hasSuffix("ping") {
                sendJSON(fd, origin: origin, ["status": "ok", "service": "ups-print-bridge"]); return
            }
            if path.hasSuffix("listprinters") || path.contains("printer") {
                if req.isNavigation {
                    BridgeLog.shared.log("GET /listPrinters (navigation) -> handshake page")
                    sendHTML(fd, origin: origin, handshakeHTML()); return
                } else {
                    sendJSON(fd, origin: origin, printerListPayload(req.query)); return
                }
            }
            sendJSON(fd, origin: origin, ["status": "ok", "service": "ups-print-bridge"]); return
        }

        if req.method == "POST" || req.method == "PUT" {
            if path.hasSuffix("probe") {
                if let s = String(data: req.body, encoding: .utf8), !s.isEmpty {
                    BridgeLog.shared.log("PROBE \(s.prefix(300))")
                }
                sendJSON(fd, origin: origin, ["status": "ok"]); return
            }
            if let zpl = ZPL.extract(body: req.body, contentType: req.headers["content-type"] ?? "") {
                // Side-effect guard: only the local handshake page, ups.com, or
                // local tools (no Origin) may trigger a print. This blocks any
                // arbitrary website you visit from printing to your label printer.
                if !originAllowedForPrint(req.headers["origin"]) {
                    BridgeLog.shared.log("BLOCKED print from origin \(req.headers["origin"] ?? "?")")
                    sendJSON(fd, origin: origin, ["status": "forbidden", "detail": "origin not allowed"], status: 403); return
                }
                let (ok, detail) = printDeduped(zpl)
                sendJSON(fd, origin: origin, ["status": ok ? "ok" : "error",
                                              "bytes": "\(zpl.count)", "detail": detail],
                         status: ok ? 200 : 500); return
            }
            sendJSON(fd, origin: origin, printerListPayload(req.query)); return
        }

        send(fd, status: 404, origin: origin)
    }

    // Only the local handshake page, ups.com, or local tools (no Origin header)
    // may print. Everything else (arbitrary websites) is rejected.
    private func originAllowedForPrint(_ origin: String?) -> Bool {
        guard let o = origin, !o.isEmpty, o != "*" else { return true }   // CLI / GM_xhr / same-process
        guard let host = URL(string: o)?.host?.lowercased() else { return false }
        if host == "127.0.0.1" || host == "localhost" { return true }
        if host == "ups.com" || host.hasSuffix(".ups.com") { return true }
        return false
    }

    // Print, skipping an identical label re-sent within the dedupe window.
    // Serialized: concurrent connections can't race the dedupe state / printer.
    private func printDeduped(_ zpl: Data) -> (Bool, String) {
        printLock.lock(); defer { printLock.unlock() }
        let sig = sha1(zpl)
        if sig == lastPrintSig && Date().timeIntervalSince(lastPrintAt) < dedupeWindow {
            BridgeLog.shared.log("PRINT skipped (identical label within \(Int(dedupeWindow))s)")
            return (true, "duplicate-skipped")
        }
        let printer = BridgeConfig.shared.printer
        guard !printer.isEmpty else { return (false, "no printer configured") }
        let (ok, detail) = Printers.send(zpl, to: printer)
        if ok { lastPrintSig = sig; lastPrintAt = Date() }
        return (ok, detail)
    }

    // MARK: responses

    private func printerListPayload(_ query: [String: String]) -> [String: Any] {
        let name = BridgeConfig.shared.printer
        let one: [String: Any] = ["name": name, "displayName": name.replacingOccurrences(of: "_", with: " "),
                                  "default": true, "isDefault": true, "status": "ready", "type": "thermal"]
        return ["status": "ok", "success": true, "defaultPrinter": name,
                "printers": [one], "printerList": [one], "availablePrinters": [one], "data": [one]]
    }

    private func corsHeaders(_ origin: String) -> String {
        return """
        Access-Control-Allow-Origin: \(origin)\r
        Vary: Origin\r
        Access-Control-Allow-Methods: GET, POST, PUT, OPTIONS, DELETE\r
        Access-Control-Allow-Headers: *\r
        Access-Control-Allow-Credentials: true\r
        Access-Control-Allow-Private-Network: true\r
        Access-Control-Max-Age: 86400\r

        """
    }

    private func send(_ fd: Int32, status: Int, origin: String) {
        let head = "HTTP/1.1 \(status) \(statusText(status))\r\n" + corsHeaders(origin)
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        writeAll(fd, Data(head.utf8))
    }

    private func sendHTML(_ fd: Int32, origin: String, _ html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\n" + corsHeaders(origin)
            + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        writeAll(fd, Data(head.utf8) + body)
    }

    private func sendJSON(_ fd: Int32, origin: String, _ obj: [String: Any], status: Int = 200) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status) \(statusText(status))\r\n" + corsHeaders(origin)
            + "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        writeAll(fd, Data(head.utf8) + body)
    }

    private func statusText(_ s: Int) -> String {
        switch s { case 200: return "OK"; case 204: return "No Content"; case 404: return "Not Found"; case 500: return "Internal Server Error"; default: return "OK" }
    }

    private func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < data.count {
                let n = write(fd, base + sent, data.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - tiny SHA-1 (for print de-dup; no CryptoKit dependency needed)

func sha1(_ data: Data) -> String {
    var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    var msg = [UInt8](data)
    let ml = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() { msg.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
    func rotl(_ x: UInt32, _ c: UInt32) -> UInt32 { (x << c) | (x >> (32 - c)) }
    var chunkStart = 0
    while chunkStart < msg.count {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let j = chunkStart + i * 4
            w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j+1]) << 16) | (UInt32(msg[j+2]) << 8) | UInt32(msg[j+3])
        }
        for i in 16..<80 { w[i] = rotl(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1) }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        for i in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch i {
            case 0..<20:  f = (b & c) | (~b & d);            k = 0x5A827999
            case 20..<40: f = b ^ c ^ d;                     k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d);   k = 0x8F1BBCDC
            default:      f = b ^ c ^ d;                      k = 0xCA62C1D6
            }
            let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = rotl(b, 30); b = a; a = t
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        chunkStart += 64
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
