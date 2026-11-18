import AppKit
import Combine
import IOKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var activeLabel = ""
    @Published var lastExitStatus: Int32?
    @Published var mode = "piv"
    @Published var finger = 1
    @Published var host = ""
    @Published var confirm = "" {
        didSet {
            if confirm.isEmpty && refreshPending {
                DispatchQueue.main.async { if !self.busy && self.confirm.isEmpty { self.refresh() } }
            }
        }
    }
    @Published var confirmedAction = [String]()
    @Published var copied = false

    var selectedDevice: Device? {
        devices.first(where: { $0.id == selected })
    }

    private var notificationPort: IONotificationPortRef?
    private var iterators = [io_iterator_t]()
    private var refreshPending = false

    func startMonitoring() {
        defer { refresh() }
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let changed: IOServiceMatchingCallback = { context, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let context else { return }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            controller.devicesChanged()
        }
        for name in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, name, IOServiceMatching("IOSerialBSDClient"),
                    changed, Unmanaged.passUnretained(self).toOpaque(), &iterator) == KERN_SUCCESS else {
                stopMonitoring()
                return
            }
            iterators.append(iterator)
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
    }

    func stopMonitoring() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port = notificationPort { IONotificationPortDestroy(port) }
        notificationPort = nil
    }

    private func devicesChanged() {
        if busy || !confirm.isEmpty {
            refreshPending = true
        } else {
            refresh()
        }
    }

    func refresh() {
        refreshPending = false
        devices = Device.connected()
        if !devices.contains(where: { $0.id == selected }) {
            selected = devices.first?.id ?? ""
        }
    }

    func run(_ arguments: [String], label: String? = nil) {
        guard !busy, let device = selectedDevice else { return }
        let backend = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cli/tinytouch")
        guard FileManager.default.isExecutableFile(atPath: backend.path) else {
            output = "The bundled tinyTouch service is missing. Reinstall the app."
            lastExitStatus = 1
            return
        }
        busy = true
        activeLabel = label ?? ("tinytouch " + arguments.joined(separator: " "))
        lastExitStatus = nil
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
                    self.lastExitStatus = status
                    self.busy = false
                    self.refresh()
                }
            }
        } catch {
            output = error.localizedDescription
            lastExitStatus = 1
            busy = false
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.5)
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct ManagerView: View {
    @StateObject private var manager = Controller()

    private var trimmedHost: String {
        manager.host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidHost: Bool {
        trimmedHost.range(of: "^[a-fA-F0-9]{16}$", options: .regularExpression) != nil
    }

    private var controlsDisabled: Bool {
        manager.devices.isEmpty || manager.busy
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    authCard
                    fingerprintCard
                }
                GridRow {
                    pairedMacsCard
                    firmwareCard
                }
            }
            .disabled(controlsDisabled)

            consolePanel
        }
        .padding(20)
        .frame(minWidth: 740, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { manager.startMonitoring() }
        .onDisappear { manager.stopMonitoring() }
        .alert(manager.confirm, isPresented: Binding(get: { !manager.confirm.isEmpty }, set: { if !$0 { manager.confirm = "" } })) {
            Button("Cancel", role: .cancel) {}
            Button("Confirm", role: .destructive) {
                manager.run(manager.confirmedAction)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "touchid")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("tinyTouch")
                        .font(.system(size: 17, weight: .bold))
                    if !appVersion.isEmpty {
                        Text("v\(appVersion)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
                Text("Hardware Fingerprint Security Key Manager")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if manager.devices.isEmpty {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Connect tinyTouch using a USB data cable.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                )
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Picker("Device", selection: $manager.selected) {
                        ForEach(manager.devices) { device in
                            Text(device.id).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                    if let port = manager.selectedDevice?.port {
                        Text(URL(fileURLWithPath: port).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh connected USB devices")
            .disabled(manager.busy)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var authCard: some View {
        SectionCard(
            title: "Mac Setup & Authentication",
            subtitle: "Shared device mode and local macOS pairing",
            icon: "lock.shield.fill",
            accent: .blue
        ) {
            Picker("Authentication", selection: $manager.mode) {
                Text("PIV smart card").tag("piv")
                Text("HID keyboard").tag("hid")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(manager.mode == "piv"
                 ? "Native smart-card authentication for macOS login, unlock, and sudo."
                 : "Encrypted password helper for universal password fields on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    manager.run(["setup", "--mode", manager.mode], label: "Setting up this Mac (\(manager.mode.uppercased()))…")
                } label: {
                    Label("Set up this Mac", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)

                if manager.mode == "hid" {
                    Button {
                        manager.run(["password"], label: "Updating HID password…")
                    } label: {
                        Label("Update HID password", systemImage: "key.fill")
                    }
                }
            }
        }
    }

    private var fingerprintCard: some View {
        SectionCard(
            title: "Fingerprints",
            subtitle: "Manage up to 10 sensor slots (4 views each)",
            icon: "touchid",
            accent: .pink
        ) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Stepper("Finger \(manager.finger)", value: $manager.finger, in: 1...10)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button {
                    manager.run(["fingers"], label: "Reading fingerprint inventory…")
                } label: {
                    Label("Fingerprints", systemImage: "list.bullet.rectangle")
                }
            }

            HStack(spacing: 8) {
                Button {
                    manager.run(["enroll", String(manager.finger)], label: "Enrolling finger \(manager.finger)…")
                } label: {
                    Label("Enroll Finger \(manager.finger)", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)

                Button(role: .destructive) {
                    manager.confirmedAction = ["delete", String(manager.finger)]
                    manager.confirm = "Delete finger \(manager.finger)"
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
        }
    }

    private var pairedMacsCard: some View {
        SectionCard(
            title: "Paired HID Macs",
            subtitle: "Inspect or revoke registered HID host slots",
            icon: "desktopcomputer",
            accent: .purple
        ) {
            HStack(spacing: 8) {
                Button {
                    manager.run(["computers"], label: "Listing paired HID Macs…")
                } label: {
                    Label("Paired HID Macs", systemImage: "laptopcomputer")
                }
                Spacer()
                Text("Max 8 hosts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Host ID (16 hex chars)", text: $manager.host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button(role: .destructive) {
                    manager.confirmedAction = ["computers", "remove", trimmedHost]
                    manager.confirm = "Revoke HID host \(trimmedHost)"
                } label: {
                    Label("Revoke", systemImage: "xmark.shield")
                }
                .disabled(!isValidHost)
            }
        }
    }

    private var firmwareCard: some View {
        SectionCard(
            title: "Device & Firmware",
            subtitle: "Status inspection, event logs, and signed USB OTA",
            icon: "cpu.fill",
            accent: .teal
        ) {
            HStack(spacing: 8) {
                Button {
                    manager.run(["status"], label: "Reading device status…")
                } label: {
                    Label("Device status", systemImage: "info.circle")
                }

                Button {
                    manager.run(["logs"], label: "Reading device event logs…")
                } label: {
                    Label("Event logs", systemImage: "doc.text.magnifyingglass")
                }
            }

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.data]
                panel.allowsOtherFileTypes = true
                panel.message = "Select a signed tinyTouch OTA firmware binary (.bin)"
                if panel.runModal() == .OK, let file = panel.url {
                    manager.run(["update", "--file", file.path], label: "Updating firmware from \(file.lastPathComponent)…")
                }
            } label: {
                Label("Update firmware from file…", systemImage: "arrow.up.doc.fill")
            }
        }
    }

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Console Output")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if manager.busy {
                    Divider().frame(height: 12)
                    ProgressView().controlSize(.small)
                    Text(manager.activeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let code = manager.lastExitStatus {
                    Divider().frame(height: 12)
                    HStack(spacing: 4) {
                        Image(systemName: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(code == 0 ? Color.green : Color.red)
                        Text(code == 0 ? "Completed" : "Exit \(code)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manager.output, forType: .string)
                    manager.copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        manager.copied = false
                    }
                } label: {
                    Label(manager.copied ? "Copied" : "Copy", systemImage: manager.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(manager.output.isEmpty)

                Button {
                    manager.output = ""
                    manager.lastExitStatus = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(manager.output.isEmpty || manager.busy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if manager.output.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(manager.busy ? "Waiting for device output…" : "Ready. Select an action above to view command output.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    } else {
                        Text(manager.output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("consoleBottom")
                    }
                }
                .onReceive(manager.$output) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("consoleBottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 165, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@main
struct TinyTouchManager: App {
    var body: some Scene {
        WindowGroup("tinyTouch") {
            ManagerView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
