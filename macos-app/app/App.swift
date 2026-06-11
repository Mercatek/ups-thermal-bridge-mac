// App.swift — the macOS app: a menu-bar item + a first-run setup wizard.
// Wraps the pure-Swift engine (HTTPServer/Bridge/Handshake). Menu-bar only
// (LSUIElement); the wizard is shown in an AppKit window we control.

import SwiftUI
import AppKit
import ServiceManagement

// MARK: - App state (singleton; owns the running server)

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var running = false
    @Published var portBusy = false
    @Published var printer: String = BridgeConfig.shared.printer
    @Published var printers: [String] = []
    @Published var lastActivity = "—"
    @Published var launchAtLogin = false

    private let server = HTTPServer(port: BridgeConfig.shared.port)

    private init() {
        server.onActivity = { [weak self] in self?.lastActivity = "request @ \(shortTime())" }
        refreshPrinters()
        if printer.isEmpty { printer = printers.first ?? ""; BridgeConfig.shared.printer = printer }
        updateLoginState()
    }

    func startServer() {
        if running { return }
        let ok = server.start()
        running = ok; portBusy = !ok
        if !ok { BridgeLog.shared.log("port \(BridgeConfig.shared.port) busy — another bridge running?") }
    }

    func refreshPrinters() { printers = Printers.list() }

    func setPrinter(_ p: String) {
        printer = p; BridgeConfig.shared.printer = p
        BridgeLog.shared.log("printer set to \(p)")
    }

    func testPrint() {
        guard !printer.isEmpty else { lastActivity = "no printer selected"; return }
        let zpl = "^XA^CI28^FO40,40^A0N,40,40^FDUPS Print Bridge^FS^FO40,100^A0N,30,30^FDTest label OK^FS^FO40,150^A0N,28,28^FD\(shortTime())^FS^XZ"
        let (ok, detail) = Printers.send(Data(zpl.utf8), to: printer)
        lastActivity = ok ? "test label sent \u{2713}" : "test failed: \(detail.prefix(40))"
    }

    func openCUPS() {
        _ = Printers.run("/usr/sbin/cupsctl", ["WebInterface=yes"])
        if let url = URL(string: "http://localhost:631/admin") { NSWorkspace.shared.open(url) }
    }
    func openUPS() {
        if let url = URL(string: "https://www.ups.com") { NSWorkspace.shared.open(url) }
    }

    func updateLoginState() {
        if #available(macOS 13.0, *) { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
    }
    func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { BridgeLog.shared.log("login item error: \(error)") }
            updateLoginState()
        }
    }
}

func shortTime() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
}

// MARK: - Wizard window (AppKit-managed so we can open it on first run)

final class WizardWindow {
    static let shared = WizardWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WizardView(state: AppState.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "UPS Print Bridge — Setup"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.setContentSize(NSSize(width: 540, height: 480))
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.setActivationPolicy(.regular)        // show in Dock while the wizard is open
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func close() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)      // back to menu-bar-only
    }
}

// MARK: - Entry

@main
struct UPSPrintBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("UPS Print Bridge", systemImage: state.running ? "printer.fill" : "printer") {
            MenuView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only by default
        AppState.shared.startServer()
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WizardWindow.shared.show() }
        }
    }
}
