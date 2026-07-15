import CoreAudio
import Foundation

/// Keeps call recording from downgrading Bluetooth headphone output.
///
/// macOS switches many Bluetooth headsets (AirPods included) into the hands-free
/// profile when their microphone is opened. That makes playback sound like a
/// phone call. For call recording we only need a local mic track, so if the
/// default input and output are the same Bluetooth headset we temporarily use a
/// built-in Mac microphone instead, then restore the user's previous default
/// input when recording stops.
enum CallInputRouting {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let transportType: UInt32
        let hasInput: Bool
        let hasOutput: Bool
    }

    static let bluetoothTransportTypes: Set<UInt32> = [
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
    ]
    static let builtInTransportType: UInt32 = kAudioDeviceTransportTypeBuiltIn

    static func replacementInputForBluetoothDuplex(
        defaultInput: Device?,
        defaultOutput: Device?,
        devices: [Device],
        bluetoothTransportTypes: Set<UInt32> = Self.bluetoothTransportTypes,
        builtInTransportType: UInt32 = Self.builtInTransportType
    ) -> Device? {
        guard let defaultInput, let defaultOutput else { return nil }
        guard defaultInput.hasInput, defaultOutput.hasOutput else { return nil }
        guard bluetoothTransportTypes.contains(defaultInput.transportType),
              bluetoothTransportTypes.contains(defaultOutput.transportType) else { return nil }
        guard sameUserFacingDeviceName(defaultInput.name, defaultOutput.name) else { return nil }

        let candidates = devices.filter { device in
            device.hasInput
                && device.transportType == builtInTransportType
                && device.id != defaultInput.id
        }
        return candidates.first { device in
            let name = device.name.lowercased()
            return name.contains("microphone") || name.contains("mic")
        } ?? candidates.first
    }

    static func shouldRestoreInput(
        currentDefaultInputID: AudioObjectID,
        originalInputID: AudioObjectID,
        replacementInputID: AudioObjectID
    ) -> Bool {
        currentDefaultInputID == replacementInputID && originalInputID != replacementInputID
    }

    static func defaultInputDeviceID() -> AudioObjectID? {
        getSystemDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        getSystemDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func allDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids.compactMap(deviceSummary)
    }

    static func deviceSummary(id: AudioObjectID) -> Device? {
        guard id != AudioObjectID(kAudioObjectUnknown),
              let name = stringProperty(
                deviceID: id,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
              ) else {
            return nil
        }
        let transport = uint32Property(
            deviceID: id,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? kAudioDeviceTransportTypeUnknown
        return Device(
            id: id,
            name: name,
            transportType: transport,
            hasInput: hasStreams(deviceID: id, scope: kAudioDevicePropertyScopeInput),
            hasOutput: hasStreams(deviceID: id, scope: kAudioDevicePropertyScopeOutput)
        )
    }

    @discardableResult
    static func setDefaultInputDevice(_ id: AudioObjectID) -> Bool {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &deviceID
        )
        return status == noErr
    }

    private static func sameUserFacingDeviceName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func getSystemDevice(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func uint32Property(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString?>.size,
            alignment: MemoryLayout<CFString?>.alignment
        )
        let typed = storage.bindMemory(to: Optional<CFString>.self, capacity: 1)
        typed.initialize(to: nil)
        defer {
            typed.deinitialize(count: 1)
            storage.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage)
        guard status == noErr, let value = typed.pointee else { return nil }
        return value as String
    }

    private static func hasStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }
}

final class CallInputRouteGuard {
    private var switchedRoute: (original: AudioObjectID, replacement: AudioObjectID)?

    func prepareForCallRecording() {
        guard switchedRoute == nil else { return }
        let devices = CallInputRouting.allDevices()
        guard let defaultInputID = CallInputRouting.defaultInputDeviceID(),
              let defaultOutputID = CallInputRouting.defaultOutputDeviceID(),
              let defaultInput = devices.first(where: { $0.id == defaultInputID }),
              let defaultOutput = devices.first(where: { $0.id == defaultOutputID }),
              let replacement = CallInputRouting.replacementInputForBluetoothDuplex(
                defaultInput: defaultInput,
                defaultOutput: defaultOutput,
                devices: devices
              ) else {
            return
        }

        if CallInputRouting.setDefaultInputDevice(replacement.id) {
            switchedRoute = (original: defaultInputID, replacement: replacement.id)
            NSLog(
                "[Voicely] Call input route: switched default input from %@ to %@ to avoid Bluetooth hands-free output quality drop",
                defaultInput.name,
                replacement.name
            )
        } else {
            NSLog("[Voicely] Call input route: failed to switch default input away from %@", defaultInput.name)
        }
    }

    func restoreIfNeeded() {
        guard let switchedRoute else { return }
        self.switchedRoute = nil
        guard let current = CallInputRouting.defaultInputDeviceID() else { return }
        guard CallInputRouting.shouldRestoreInput(
            currentDefaultInputID: current,
            originalInputID: switchedRoute.original,
            replacementInputID: switchedRoute.replacement
        ) else {
            NSLog("[Voicely] Call input route: default input changed during recording; leaving user's current choice intact")
            return
        }
        if CallInputRouting.setDefaultInputDevice(switchedRoute.original) {
            NSLog("[Voicely] Call input route: restored previous default input")
        }
    }
}
