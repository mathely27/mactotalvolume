import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let processObjectIDs: [AudioObjectID]
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
            guard let baseAddress = buffer.baseAddress else { return OSStatus(-50) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount,
                baseAddress
            )
        }
        guard processReadStatus == noErr else {
            return []
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let appsByPID = Dictionary(uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) })
        let appsByBundleID = Dictionary(
            runningApps.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        var processes: [(id: String, name: String, objectID: AudioObjectID)] = []

        for processObjectID in processIDs {
            guard let isRunningOutput = readUInt32(
                processObjectID, selector: kAudioProcessPropertyIsRunningOutput
            ), isRunningOutput != 0,
               let pid = readPID(processObjectID, selector: kAudioProcessPropertyPID) else {
                continue
            }

            let processBundleID = readBundleID(processObjectID)
            let app = appsByPID[pid] ?? processBundleID.flatMap { appsByBundleID[$0] }
            let bundleID = app?.bundleIdentifier ?? processBundleID
            let id = bundleID ?? "pid:\(pid)"
            let name = app?.localizedName ?? bundleID ?? "Audio process (PID \(pid))"
            processes.append((id, name, processObjectID))
        }

        let grouped = Dictionary(grouping: processes, by: \.id)
        return grouped.map { id, group in
            AudioApp(id: id, name: group[0].name, processObjectIDs: group.map(\.objectID))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func readBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID) == noErr else {
            return nil
        }
        return bundleID as String?
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

/// Captures one app's output through a Core Audio process tap, applies gain,
/// and sends it back to the current output device through AVAudioEngine.
final class AppVolumeTap {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private let engine = AVAudioEngine()

    init(processObjectIDs: [AudioObjectID], gain: Float) throws {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.name = "Mactotalvolume app mixer"
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else { throw MixerError.coreAudio(tapStatus) }
        self.tapID = tapID

        do {
            let tapUID = try Self.tapUID(tapID)
            let aggregateUID = "com.mathely.mactotalvolume.tap.\(UUID().uuidString)"
            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey as String: tapUID,
                kAudioSubTapDriftCompensationKey as String: true
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "Mactotalvolume private audio route",
                kAudioAggregateDeviceUIDKey as String: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceIsStackedKey as String: false,
                kAudioAggregateDeviceTapListKey as String: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey as String: true
            ]

            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &aggregateID
            )
            guard aggregateStatus == noErr else { throw MixerError.coreAudio(aggregateStatus) }
            aggregateDeviceID = aggregateID

            guard let inputUnit = engine.inputNode.audioUnit else {
                throw MixerError.message("macOS did not provide an audio input unit.")
            }
            var selectedDevice = aggregateID
            let inputStatus = AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
            guard inputStatus == noErr else { throw MixerError.coreAudio(inputStatus) }

            let input = engine.inputNode
            engine.connect(input, to: engine.mainMixerNode, format: input.outputFormat(forBus: 0))
            engine.mainMixerNode.outputVolume = min(max(gain, 0), 1)
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ gain: Float) {
        engine.mainMixerNode.outputVolume = min(max(gain, 0), 1)
    }

    func stop() {
        engine.stop()
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func tapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw MixerError.coreAudio(status) }
        return uid as String
    }
}

enum MixerError: LocalizedError {
    case coreAudio(OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status): "Core Audio error: \(status)"
        case .message(let text): text
        }
    }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var lastUpdated = Date()
    @Published private(set) var volumes: [String: Double] = [:]
    @Published var errorMessage: String?

    private var timer: Timer?
    private var taps: [String: AppVolumeTap] = [:]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let nextApps = AudioProcessMonitor.activeOutputApps()
        let liveIDs = Set(nextApps.map(\.id))
        for oldID in taps.keys where !liveIDs.contains(oldID) {
            taps.removeValue(forKey: oldID)?.stop()
            volumes.removeValue(forKey: oldID)
        }
        for app in nextApps where volumes[app.id] == nil {
            volumes[app.id] = 1
        }
        apps = nextApps
        lastUpdated = Date()
    }

    func setVolume(_ volume: Double, for app: AudioApp) {
        let value = min(max(volume, 0), 1)
        if abs(value - 1) < 0.005 {
            taps.removeValue(forKey: app.id)?.stop()
            volumes[app.id] = 1
            errorMessage = nil
            return
        }

        do {
            if let tap = taps[app.id] {
                tap.setGain(Float(value))
            } else {
                taps[app.id] = try AppVolumeTap(
                    processObjectIDs: app.processObjectIDs,
                    gain: Float(value)
                )
            }
            volumes[app.id] = value
            errorMessage = nil
        } catch {
            taps.removeValue(forKey: app.id)?.stop()
            volumes[app.id] = 1
            errorMessage = "Couldn't control this app's audio. \(error.localizedDescription)"
        }
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
                    Text("Individual app volume controls")
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
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.apps) { app in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: model.volumes[app.id, default: 1] == 0
                                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(app.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(Int(model.volumes[app.id, default: 1] * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 38, alignment: .trailing)
                                }
                                Slider(
                                    value: Binding(
                                        get: { model.volumes[app.id, default: 1] },
                                        set: { model.setVolume($0, for: app) }
                                    ),
                                    in: 0...1
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
