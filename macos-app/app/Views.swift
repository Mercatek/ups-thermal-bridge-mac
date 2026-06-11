// Views.swift — the menu-bar popover (MenuView) and the setup wizard (WizardView).

import SwiftUI

private let navy = Color(red: 0.05, green: 0.17, blue: 0.30)
private let gold = Color(red: 0.79, green: 0.66, blue: 0.30)

// MARK: - Menu-bar popover

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(state.running ? .green : (state.portBusy ? .orange : .red)).frame(width: 9, height: 9)
                Text(state.running ? "Service running · port 4349"
                     : (state.portBusy ? "Port 4349 busy (another bridge?)" : "Service stopped"))
                    .font(.system(size: 12, weight: .medium))
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Printer").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: Binding(
                        get: { state.printer },
                        set: { state.setPrinter($0) })) {
                        if state.printers.isEmpty { Text("No printers found").tag("") }
                        ForEach(state.printers, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Button { state.refreshPrinters() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
            }

            Button { state.testPrint() } label: {
                Label("Print a test label", systemImage: "printer.dotmatrix")
            }.disabled(state.printer.isEmpty)

            Button { state.openUPS() } label: {
                Label("Open ups.com", systemImage: "shippingbox")
            }

            Toggle("Launch at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }))
                .font(.system(size: 12))

            Divider()

            Text(state.lastActivity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)

            HStack {
                Button("Setup guide…") { WizardWindow.shared.show() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Setup wizard

struct WizardView: View {
    @ObservedObject var state: AppState
    @State private var step = 0
    @State private var testAsked = false

    var body: some View {
        VStack(spacing: 0) {
            // header
            HStack(spacing: 10) {
                Image(systemName: "printer.fill").font(.system(size: 22)).foregroundStyle(gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UPS Print Bridge").font(.system(size: 17, weight: .bold))
                    Text("Print UPS thermal labels on your Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(step + 1)/4").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(navy.opacity(0.06))

            Divider()

            Group {
                switch step {
                case 0: welcome
                case 1: printerStep
                case 2: testStep
                default: doneStep
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // footer nav
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                navButton
            }
            .padding(16)
        }
    }

    // step 0
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome 👋").font(.system(size: 20, weight: .semibold))
            Text("This sets up a tiny local service so you can print UPS thermal (ZPL) labels straight from ups.com to your label printer — no Windows-only app needed.")
                .fixedSize(horizontal: false, vertical: true)
            Text("You'll need:").font(.system(size: 13, weight: .medium)).padding(.top, 4)
            Label("A thermal label printer (Zebra/Bixolon/Eltron) added to macOS", systemImage: "printer")
            Label("Google Chrome with a UPS account", systemImage: "globe")
            Spacer()
        }.font(.system(size: 13))
    }

    // step 1
    private var printerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your printer").font(.system(size: 17, weight: .semibold))
            if state.printers.isEmpty {
                Text("No printers found in macOS yet.").foregroundStyle(.orange)
                Text("Add your thermal printer as a **Raw** queue, then come back and refresh:")
                    .fixedSize(horizontal: false, vertical: true)
                Button { state.openCUPS() } label: { Label("Open printer setup (CUPS)", systemImage: "plus.square") }
            } else {
                Text("Pick the label printer to print to:").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { state.printer }, set: { state.setPrinter($0) })) {
                    ForEach(state.printers, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.radioGroup)
            }
            HStack {
                Button { state.refreshPrinters() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { state.openCUPS() } label: { Text("Open CUPS…") }.buttonStyle(.link)
            }.padding(.top, 4)
            Spacer()
        }.font(.system(size: 13))
    }

    // step 2
    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test the printer").font(.system(size: 17, weight: .semibold))
            Text("Printing to **\(state.printer.isEmpty ? "—" : state.printer)**. Print a small test label to confirm it works:")
                .fixedSize(horizontal: false, vertical: true)
            Button { state.testPrint(); testAsked = true } label: {
                Label("Print test label", systemImage: "printer.dotmatrix")
            }.disabled(state.printer.isEmpty)
            if testAsked {
                Text("Did a label come out of the printer?").padding(.top, 6)
                Text("If not: your queue is probably not a **Raw** queue — open CUPS and re-add it as Raw/Raw Queue.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(state.lastActivity).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }.font(.system(size: 13))
    }

    // step 3
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All set ✅").font(.system(size: 20, weight: .semibold))
            Text("Now just click **Print Thermal Label** on ups.com — from a label page or from Shipping History. The label prints on \(state.printer.isEmpty ? "your printer" : state.printer).")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Launch automatically at login (recommended)", isOn: Binding(
                get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            Text("The service lives in your menu bar (the 🖨️ icon). You can change the printer or print a test from there anytime.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }.font(.system(size: 13))
    }

    @ViewBuilder private var navButton: some View {
        if step < 3 {
            Button(step == 0 ? "Get started" : "Next") { step += 1 }
                .keyboardShortcut(.defaultAction)
                .disabled(step == 1 && state.printer.isEmpty)
        } else {
            Button("Finish") {
                UserDefaults.standard.set(true, forKey: "didOnboard")
                WizardWindow.shared.close()
            }.keyboardShortcut(.defaultAction)
        }
    }
}
