import AppKit
import Combine
import IOKit
import SwiftUI

struct Device: Hashable, Identifiable {
    let id: String
    let port: String

    static func connected() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ name: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, "IOService", name as CFString, nil,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard property("idVendor") as? Int == 0x303a,
                  property("idProduct") as? Int == 0x4001,
                  let serial = property("USB Serial Number") as? String,
                  serial.range(of: "^TT-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil,
                  let port = property("IOCalloutDevice") as? String else { continue }
            result.append(Device(id: serial.uppercased(), port: port))
        }
        return result.sorted { $0.id < $1.id }
    }
}

@MainActor
final class Controller: ObservableObject {
    @Published var devices = [Device]()
    @Published var selected = ""
    @Published var output = ""
    @Published var busy = false

    func refresh() {
        devices = Device.connected()
        if !devices.contains(where: { $0.id == selected }) {
            selected = devices.first?.id ?? ""
        }
    }

    func run(_ arguments: [String]) {
        guard !busy, let device = devices.first(where: { $0.id == selected }) else { return }
        let backend = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cli/tinytouch")
        guard FileManager.default.isExecutableFile(atPath: backend.path) else {
            output = "The bundled tinyTouch service is missing. Reinstall the app."
            return
        }
        busy = true
        output = ""
        let process = Process()
        process.executableURL = backend
        process.arguments = ["--port", device.port] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TINYTOUCH_GUI": "1", "TINYTOUCH_GUI_DEVICE": device.id, "NO_COLOR": "1"
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            // Drain in one reader so the last line is displayed before completion.
            DispatchQueue.global().async {
                var pending = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    pending.append(chunk)
                    if let end = pending.lastIndex(of: 10) {
                        let lines = String(decoding: pending[...end], as: UTF8.self)
                        pending.removeSubrange(...end)
                        DispatchQueue.main.async { self.output += lines }
                    }
                    if chunk.isEmpty { break }
                }
                process.waitUntilExit()
                let tail = String(decoding: pending, as: UTF8.self)
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    self.output += tail
                    if status != 0 { self.output += "\nAction failed (\(status))." }
                    self.busy = false
                    self.refresh()
                }
            }
        } catch {
            output = error.localizedDescription
            busy = false
        }
    }
}

struct ManagerView: View {
    @StateObject private var manager = Controller()
    @State private var mode = "piv"
    @State private var finger = 1
    @State private var host = ""
    @State private var confirm = ""
    @State private var confirmedAction = [String]()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if manager.devices.isEmpty {
                Text("Connect tinyTouch using a USB data cable.")
            } else {
                Picker("Device", selection: $manager.selected) {
                    ForEach(manager.devices) { Text($0.id).tag($0.id) }
                }
            }
            Group {
                HStack {
                    Picker("Authentication", selection: $mode) {
                        Text("PIV smart card").tag("piv")
                        Text("HID keyboard").tag("hid")
                    }
                    Button("Set up this Mac") { manager.run(["setup", "--mode", mode]) }
                    if mode == "hid" {
                        Button("Update HID password") { manager.run(["password"]) }
                    }
                }
                HStack {
                    Button("Device status") { manager.run(["status"]) }
                    Button("Fingerprints") { manager.run(["fingers"]) }
                    Stepper("Finger \(finger)", value: $finger, in: 1...10)
                    Button("Enroll") { manager.run(["enroll", String(finger)]) }
                    Button("Delete") { confirmedAction = ["delete", String(finger)]
                        confirm = "Delete finger \(finger)" }
                }
                HStack {
                    Button("Paired HID Macs") { manager.run(["computers"]) }
                    TextField("Host ID", text: $host)
                    Button("Revoke") { confirmedAction = ["computers", "remove", host]
                        confirm = "Revoke HID host \(host)" }
                        .disabled(host.range(of: "^[a-fA-F0-9]{16}$", options: .regularExpression) == nil)
                }
                Button("Update firmware from file…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let file = panel.url {
                        manager.run(["update", "--file", file.path])
                    }
                }
            }.disabled(manager.devices.isEmpty || manager.busy)
            if manager.busy { ProgressView().controlSize(.small) }
            ScrollView {
                Text(manager.output).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24).frame(minWidth: 640, minHeight: 430)
        .onAppear { manager.refresh() }
        .onReceive(timer) { _ in if !manager.busy && confirm.isEmpty { manager.refresh() } }
        .alert(confirm, isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = "" } })) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm", role: .destructive) {
                manager.run(confirmedAction)
            }
        }
    }
}

@main
struct TinyTouchManager: App {
    var body: some Scene {
        WindowGroup("tinyTouch") { ManagerView() }.commands { CommandGroup(replacing: .newItem) {} }
    }
}
