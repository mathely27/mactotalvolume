import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import SwiftUI

struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let processObjectIDs: [AudioObjectID]

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.processObjectIDs == rhs.processObjectIDs
    }
}

/// Reads the Core Audio process list and maps audio process IDs to app names.
/// Chromium and other apps may expose helper processes; keeping them separate
/// lets each active audio process receive its own tap and control.
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
        var processes: [(id: String, name: String, objectID: AudioObjectID, app: NSRunningApplication?)] = []

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
            let id = "pid:\(pid)"
            let name = app?.localizedName ?? bundleID ?? "Audio process (PID \(pid))"
            processes.append((id, name, processObjectID, app))
        }

        return processes.map { process in
            let icon = process.app?.icon ?? NSWorkspace.shared.icon(forFileType: "app")
            return AudioApp(id: process.id, name: process.name, icon: icon,
                            processObjectIDs: [process.objectID])
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

/// Captures one app through a Core Audio process tap, changes its gain, and
/// sends the processed audio through the engine's normal Mac output device.
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

            try Self.selectDevice(aggregateID, for: engine.inputNode.audioUnit,
                                  message: "macOS did not provide an audio input unit.")

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw MixerError.message(
                    "The audio tap has no active input format. Start app audio and try again."
                )
            }
            engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
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

    private static func selectDevice(
        _ deviceID: AudioObjectID,
        for audioUnit: AudioUnit?,
        message: String
    ) throws {
        guard let audioUnit else { throw MixerError.message(message) }
        var selectedDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else { throw MixerError.coreAudio(status) }
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
    private var rememberedVolumes: [String: Double] = [:]

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let nextApps = AudioProcessMonitor.activeOutputApps()
        let liveIDs = Set(nextApps.map(\.id))
        for oldID in Array(taps.keys) where !liveIDs.contains(oldID) {
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
            if value > 0.01 { rememberedVolumes[app.id] = value }
            errorMessage = nil
        } catch {
            taps.removeValue(forKey: app.id)?.stop()
            volumes[app.id] = 1
            errorMessage = "Couldn't control this app's audio. \(error.localizedDescription)"
        }
    }

    func toggleMute(for app: AudioApp) {
        if volumes[app.id, default: 1] <= 0.01 {
            setVolume(rememberedVolumes[app.id, default: 0.5], for: app)
        } else {
            rememberedVolumes[app.id] = volumes[app.id, default: 1]
            setVolume(0, for: app)
        }
    }
}

struct MixerPopover: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.apps.isEmpty {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(model.apps) { app in
                            HStack(spacing: 10) {
                                Button { model.toggleMute(for: app) } label: {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 22, height: 22)
                                        .overlay(alignment: .bottomTrailing) {
                                            if model.volumes[app.id, default: 1] <= 0.01 {
                                                Image(systemName: "speaker.slash.fill")
                                                    .font(.system(size: 8, weight: .bold))
                                                    .padding(2)
                                                    .background(.regularMaterial, in: Circle())
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .help("Mute or unmute \(app.name)")

                                Text(app.name)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .frame(width: 112, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { model.volumes[app.id, default: 1] },
                                        set: { model.setVolume($0, for: app) }
                                    ),
                                    in: 0...1
                                )
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(width: 345)
        .alert("Couldn't adjust volume", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Try again.")
        }
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
