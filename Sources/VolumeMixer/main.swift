import AppKit
import Combine
import CoreAudio
import SwiftUI

struct AudioApp: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }
}

/// Reads the Core Audio process list and maps audio process IDs to app names.
/// Chromium and other apps may expose helper processes; those are shown by PID
/// until we add app/helper grouping in the mixer engine.
enum AudioProcessMonitor {
    static func activeOutputApps() -> [AudioApp] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr, byteCount > 0 else {
            return []
        }

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.stride
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        let processReadStatus = processIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount,
                buffer.baseAddress
            )
        }
        guard processReadStatus == noErr else {
            return []
        }

        let runningApps = NSWorkspace.shared.runningApplications
        var result: [AudioApp] = []

        for processObjectID in processIDs {
            guard let isRunningOutput = readUInt32(
                processObjectID, selector: kAudioProcessPropertyIsRunningOutput
            ), isRunningOutput != 0,
               let pid = readPID(processObjectID, selector: kAudioProcessPropertyPID) else {
                continue
            }

            let app = runningApps.first { $0.processIdentifier == pid }
            let name = app?.localizedName ?? "Audio process (PID \(pid))"
            result.append(AudioApp(pid: pid, name: name))
        }

        return result
            .reduce(into: [pid_t: AudioApp]()) { $0[$1.pid] = $1 }
            .values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    private static func readPID(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var lastUpdated = Date()

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        apps = AudioProcessMonitor.activeOutputApps()
        lastUpdated = Date()
    }
}

struct MixerPopover: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Volume Mixer")
                        .font(.headline)
                    Text("Apps currently playing audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh audio apps")
            }

            Divider()

            if model.apps.isEmpty {
                ContentUnavailableView(
                    "No active audio",
                    systemImage: "speaker.slash",
                    description: Text("Start playing something in an app and it will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 125)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.apps) { app in
                            HStack(spacing: 10) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(app.name)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("Playing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            if app.id != model.apps.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()
            HStack {
                Text("Updates automatically")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.plain)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

@main
struct VolumeMixerApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            MixerPopover()
                .environmentObject(model)
        } label: {
            Image(systemName: "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)
    }
}
