import CoreAudio
import Foundation
import OSLog

@MainActor
final class DictationAudioDucker {
    struct Output {
        let deviceUID: String
        let read: () throws -> Float
        let write: (Float) throws -> Void
    }

    private struct Snapshot {
        let output: Output
        var volume: DictationVolumeSnapshot
    }

    private static let logger = Logger(subsystem: "com.tinycast", category: "DictationVolume")
    private let fileURL: URL
    private let defaultOutput: () throws -> Output?
    private let resolveOutput: (String) throws -> Output?
    private var snapshot: Snapshot?
    private var transition: Task<Void, Never>?

    init(
        fileURL: URL = AppPaths.applicationSupport().appending(path: "dictation-volume.json"),
        defaultOutput: @escaping () throws -> Output? = { DictationAudioDucker.defaultOutput() },
        resolveOutput: @escaping (String) throws -> Output? = {
            DictationAudioDucker.output(forUID: $0)
        }
    ) {
        self.fileURL = fileURL
        self.defaultOutput = defaultOutput
        self.resolveOutput = resolveOutput
    }

    deinit {MainActor.assumeIsolated { transition?.cancel() }}

    func recover() {
        schedule { _ = try await $0.recoverSavedVolume() }
    }

    func begin() {
        schedule { ducker in
            if ducker.snapshot == nil {
                guard try await ducker.recoverSavedVolume(),
                    let output = try ducker.defaultOutput()
                else { return }
                let original = try output.read()
                let volume = DictationVolumeSnapshot(
                    deviceUID: output.deviceUID, original: original, lastSet: original)
                guard volume.isValid, original > 0 else { return }
                ducker.snapshot = Snapshot(output: output, volume: volume)
            }
            guard let snapshot = ducker.snapshot else { return }
            try await ducker.fade(to: snapshot.volume.original * 0.1, release: false)
        }
    }

    func end() {
        guard snapshot != nil || transition != nil else { return }
        schedule { ducker in
            guard let snapshot = ducker.snapshot else { return }
            try await ducker.fade(to: snapshot.volume.original, release: true)
        }
    }

    func restoreImmediately() {
        transition?.cancel()
        if let snapshot, let current = try? snapshot.output.read(), snapshot.volume.matches(current) {
            do { try snapshot.output.write(snapshot.volume.original) } catch {
                Self.logger.error("Couldn't restore dictation volume: \(error.localizedDescription)")
            }
        }
        snapshot = nil
        recover()
    }

    func waitForTransition() async {
        while let transition { await transition.value }
    }

    private func schedule(_ operation: @escaping @MainActor (DictationAudioDucker) async throws -> Void) {
        let previous = transition
        previous?.cancel()
        transition = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            do { try await operation(self) } catch is CancellationError {
            } catch {
                Self.logger.error("Couldn't update dictation volume: \(error.localizedDescription)")
                if snapshot != nil { restoreImmediately() }
            }
            if !Task.isCancelled { transition = nil }
        }
    }

    private func fade(to target: Float, release: Bool) async throws {
        guard let snapshot else { return }
        let start = try snapshot.output.read()
        guard snapshot.volume.matches(start) else {
            try await clear()
            return
        }
        for step in 1...16 {
            try Task.checkCancellation()
            guard let snapshot = self.snapshot else { return }
            let volume = start + (target - start) * Float(step) / 16
            var saved = snapshot.volume
            saved.previous = saved.lastSet
            saved.lastSet = volume
            // A crash between persistence and the hardware write must recover either volume.
            try await persist(saved)
            try Task.checkCancellation()
            guard snapshot.volume.matches(try snapshot.output.read()) else {
                try await clear()
                return
            }
            try snapshot.output.write(volume)
            self.snapshot?.volume.lastSet = try snapshot.output.read()
            self.snapshot?.volume.previous = nil
            if step < 16 { try await Task.sleep(for: .milliseconds(30)) }
        }
        if release { try await clear() }
    }

    private func recoverSavedVolume() async throws -> Bool {
        let fileURL = fileURL
        let volume = try await Task.detached(priority: .utility) { () -> DictationVolumeSnapshot? in
            do {
                return try JSONDecoder().decode(DictationVolumeSnapshot.self, from: Data(contentsOf: fileURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }.value
        try Task.checkCancellation()
        guard let volume else { return true }
        guard volume.isValid else { try await persist(nil); return true }
        guard let output = try resolveOutput(volume.deviceUID) else { return false }
        let current = try output.read()
        if volume.matches(current), current != volume.original { try output.write(volume.original) }
        try await persist(nil)
        return true
    }

    private func clear() async throws {
        snapshot = nil
        try await persist(nil)
    }

    private func persist(_ volume: DictationVolumeSnapshot?) async throws {
        let fileURL = fileURL
        try await Task.detached(priority: .utility) {
            if let volume {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try JSONEncoder().encode(volume).write(to: fileURL, options: .atomic)
            } else {
                do { try FileManager.default.removeItem(at: fileURL) } catch let error as CocoaError
                    where error.code == .fileNoSuchFile
                {}
            }
        }.value
    }

    private static func defaultOutput() -> Output? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return output(for: device)
    }

    private static func output(forUID uid: String) -> Output? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let qualifier = uid as CFString
        let status = withUnsafePointer(to: qualifier) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return output(for: device)
    }

    private static func output(for device: AudioDeviceID) -> Output? {
        guard let uid = deviceUID(of: device), let address = volumeAddress(of: device) else {
            return nil
        }
        return Output(
            deviceUID: uid,
            read: { try volume(address, of: device) },
            write: { try setVolume($0, address: address, of: device) })
    }

    private static func deviceUID(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Devices expose the main element or channels 1…; take the first scalar volume control found.
    private static func volumeAddress(of device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            if AudioObjectHasProperty(device, &address) { return address }
        }
        return nil
    }

    private static func volume(
        _ address: AudioObjectPropertyAddress, of device: AudioDeviceID
    ) throws -> Float {
        var address = address
        var value = Float.zero
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw halError(status) }
        return value
    }

    private static func setVolume(
        _ volume: Float, address: AudioObjectPropertyAddress, of device: AudioDeviceID
    ) throws {
        var address = address
        var value = volume
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
        guard status == noErr else { throw halError(status) }
    }

    private static func halError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}
