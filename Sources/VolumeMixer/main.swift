import AppKit
import AudioToolbox
import Combine
import CoreAudio
import os
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
    private static let mixerBundleID = "com.mathely.mactotalvolume"

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
            let processApp = appsByPID[pid] ?? processBundleID.flatMap { appsByBundleID[$0] }
            // Helper processes (Chromium renderers, media helpers, etc.) should
            // use their parent app's name and icon while keeping a separate PID
            // so each independently audible process still gets its own slider.
            let parentApp = processBundleID.flatMap { bundleID in
                runningApps
                    .filter { app in
                        guard let parentID = app.bundleIdentifier else { return false }
                        return !parentID.localizedCaseInsensitiveContains(".helper")
                            && bundleID.hasPrefix(parentID + ".")
                    }
                    .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            }
            let app = parentApp ?? processApp
            let bundleID = app?.bundleIdentifier ?? processBundleID
            guard bundleID != mixerBundleID else { continue }
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

/// Holds a lock-free gain value read from Core Audio's real-time I/O callback.
final class GainStorage: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Float(1))

    var value: Float {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Captures a process with a tap, then applies gain directly in the aggregate
/// device's Core Audio callback before sending samples to the physical output.
final class AppVolumeTap: @unchecked Sendable {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private let gainStorage = GainStorage()

    init(processObjectIDs: [AudioObjectID], gain: Float) throws {
        gainStorage.value = min(max(gain, 0), 1)

        let outputUID = try Self.defaultOutputDeviceUID()
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.name = "Mactotalvolume app mixer"
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        tapDescription.deviceUID = outputUID

        var tapID = AudioObjectID(kAudioObjectUnknown)
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
            let outputEntry: [String: Any] = [
                kAudioSubDeviceUIDKey as String: outputUID,
                kAudioSubDeviceDriftCompensationKey as String: false
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey as String: "Mactotalvolume private audio route",
                kAudioAggregateDeviceUIDKey as String: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceIsStackedKey as String: false,
                kAudioAggregateDeviceSubDeviceListKey as String: [outputEntry],
                kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
                kAudioAggregateDeviceTapListKey as String: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey as String: true
            ]

            var aggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &aggregateID
            )
            guard aggregateStatus == noErr else { throw MixerError.coreAudio(aggregateStatus) }
            aggregateDeviceID = aggregateID

            let gainStorage = self.gainStorage
            var procID: AudioDeviceIOProcID?
            let procStatus = AudioDeviceCreateIOProcIDWithBlock(
                &procID, aggregateID, nil
            ) { _, inputData, _, outputData, _ in
                Self.copyAudio(inputData, to: outputData, gain: gainStorage.value)
            }
            guard procStatus == noErr, let procID else {
                throw MixerError.coreAudio(procStatus)
            }
            ioProcID = procID

            let startStatus = AudioDeviceStart(aggregateID, procID)
            guard startStatus == noErr else { throw MixerError.coreAudio(startStatus) }
            isStarted = true
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ gain: Float) {
        gainStorage.value = min(max(gain, 0), 1)
    }

    func stop() {
        if isStarted, aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            isStarted = false
        }
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func copyAudio(
        _ inputData: UnsafePointer<AudioBufferList>,
        to outputData: UnsafeMutablePointer<AudioBufferList>,
        gain: Float
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard !outputBuffers.isEmpty else { return }

        guard !inputBuffers.isEmpty else {
            for output in outputBuffers {
                if let data = output.mData {
                    memset(data, 0, Int(output.mDataByteSize))
                }
            }
            return
        }

        let channelOffsets = inputBuffers.reduce(into: [UInt32]()) { offsets, buffer in
            offsets.append((offsets.last ?? 0) + buffer.mNumberChannels)
        }
        let totalInputChannels = channelOffsets.last ?? 0
        guard totalInputChannels > 0 else { return }

        for (outputIndex, output) in outputBuffers.enumerated() {
            guard let outputData = output.mData else { continue }
            let outputChannels = max(output.mNumberChannels, 1)
            let outputFrames = Int(output.mDataByteSize) / MemoryLayout<Float>.size / Int(outputChannels)

            for localChannel in 0..<Int(outputChannels) {
                let globalChannel = (outputBuffers[..<outputIndex].reduce(0) { $0 + Int($1.mNumberChannels) } + localChannel) % Int(totalInputChannels)
                guard let inputIndex = channelOffsets.firstIndex(where: { Int($0) > globalChannel }) else { continue }
                let firstChannel = inputIndex == 0 ? 0 : Int(channelOffsets[inputIndex - 1])
                let input = inputBuffers[inputIndex]
                guard let inputData = input.mData else { continue }
                let inputChannels = max(input.mNumberChannels, 1)
                let channelInBuffer = globalChannel - firstChannel
                let inputFrames = Int(input.mDataByteSize) / MemoryLayout<Float>.size / Int(inputChannels)
                let frames = min(outputFrames, inputFrames)
                let source = inputData.assumingMemoryBound(to: Float.self)
                let destination = outputData.assumingMemoryBound(to: Float.self)

                for frame in 0..<frames {
                    let sourceIndex = frame * Int(inputChannels) + channelInBuffer
                    let destinationIndex = frame * Int(outputChannels) + localChannel
                    destination[destinationIndex] = source[sourceIndex] * gain
                }
                if frames < outputFrames {
                    for frame in frames..<outputFrames {
                        destination[frame * Int(outputChannels) + localChannel] = 0
                    }
                }
            }
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

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw MixerError.coreAudio(status)
        }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)
        let uidStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard uidStatus == noErr else { throw MixerError.coreAudio(uidStatus) }
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
        // Keep the audio callback alive at the slider's zero position. A true
        // stream of all-zero samples can make some browser audio clients stall;
        // -80 dB is effectively silent, but can be raised immediately again.
        let callbackGain = value == 0 ? 0.0001 : Float(value)
        do {
            if let tap = taps[app.id] {
                tap.setGain(callbackGain)
            } else {
                taps[app.id] = try AppVolumeTap(
                    processObjectIDs: app.processObjectIDs,
                    gain: callbackGain
                )
            }
            volumes[app.id] = value
            if value > 0 { rememberedVolumes[app.id] = value }
            errorMessage = nil
        } catch {
            taps.removeValue(forKey: app.id)?.stop()
            volumes[app.id] = volumes[app.id] ?? 1
            errorMessage = "Couldn't control this app's audio. \(error.localizedDescription)"
        }
    }

    func toggleMute(for app: AudioApp) {
        if volumes[app.id, default: 1] == 0 {
            setVolume(rememberedVolumes[app.id, default: 0.5], for: app)
        } else {
            rememberedVolumes[app.id] = volumes[app.id, default: 1]
            setVolume(0, for: app)
        }
    }
}

struct MixerPopover: View {
    @EnvironmentObject private var model: MixerModel

    private func volumeLabel(for app: AudioApp) -> String {
        let volume = model.volumes[app.id] ?? 1
        let percentage = Int(volume * 100)
        return "\(percentage)%"
    }

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
                                VStack(spacing: 6) {
                                    HStack(spacing: 10) {
                                        Button { model.toggleMute(for: app) } label: {
                                            Image(nsImage: app.icon)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 25, height: 25)
                                                .overlay(alignment: .bottomTrailing) {
                                                    if model.volumes[app.id, default: 1] == 0 {
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
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(volumeLabel(for: app))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 34, alignment: .trailing)
                                    }

                                    Slider(
                                        value: Binding(
                                            get: { model.volumes[app.id, default: 1] },
                                            set: { model.setVolume($0, for: app) }
                                        ),
                                        in: 0...1
                                    )
                                    .tint(.primary.opacity(0.8))
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .frame(width: 310)
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
