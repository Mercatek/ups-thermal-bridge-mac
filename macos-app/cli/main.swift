// Phase 1 test harness: run the engine headless to validate it against live
// ups.com before wrapping it in UI.  Build with ./build-cli.sh, then:
//   UPS_BRIDGE_PRINTER=Bixolon_SRP770III ./build/ups-bridge-cli
// and print from ups.com exactly as with the Python bridge.

import Foundation

if let p = ProcessInfo.processInfo.environment["UPS_BRIDGE_PRINTER"], !p.isEmpty {
    BridgeConfig.shared.printer = p
}
if BridgeConfig.shared.printer.isEmpty {
    BridgeConfig.shared.printer = Printers.list().first ?? "Bixolon_SRP770III"
}
BridgeLog.shared.onLine = { print($0) }

let server = HTTPServer(port: BridgeConfig.shared.port)
guard server.start() else {
    FileHandle.standardError.write(Data("ERROR: port \(BridgeConfig.shared.port) already in use (another bridge running?)\n".utf8))
    exit(1)
}
print("ups-bridge-cli running on 127.0.0.1:\(BridgeConfig.shared.port)  printer=\(BridgeConfig.shared.printer)")
print("printers found: \(Printers.list())")
RunLoop.main.run()
