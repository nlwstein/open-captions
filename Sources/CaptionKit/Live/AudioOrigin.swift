import Foundation

#if canImport(CoreAudio)
import CoreAudio
#endif

/// Where the live audio is coming from, in the form the status display needs it.
///
/// This exists because the first question asked of any smoke test is "was it listening to the right
/// thing at all?", and none of the ways that goes wrong are visible in the transcript. A Bluetooth
/// headset that silently switched to hands-free mode, a laptop microphone chosen while a conference
/// mic sat plugged in, a file that was not the recording anyone thought it was — every one of those
/// looks exactly like the model being bad.
public struct AudioOrigin: Sendable, Equatable {

    public enum Kind: String, Sendable {
        case microphone = "mic"
        case file = "file"
    }

    public var kind: Kind

    /// A device name, or a file's name.
    public var name: String

    /// Sample rate and transport for a device, or length and rate for a file. Shown dimmed after
    /// the name, and dropped one at a time when the terminal is too narrow — the name matters more
    /// than the rate, and both matter more than the title.
    public var details: [String]

    /// Length in seconds. Nil for a microphone, which has no end.
    public var duration: Double?

    public init(kind: Kind, name: String, details: [String] = [], duration: Double? = nil) {
        self.kind = kind
        self.name = name
        self.details = details
        self.duration = duration
    }
}

#if os(macOS)

/// Reads the system's default input device.
///
/// Deliberately CoreAudio rather than anything on `AVAudioEngine`: the engine can only answer this
/// after capture has started, and the point is to be able to say what the microphone is *before*
/// the first word arrives. A device that changes mid-session is also worth seeing, and re-reading it
/// costs a few microseconds.
public enum AudioInputDevice {

    public static func current() -> AudioOrigin {
        guard let id = defaultInputDevice() else {
            return AudioOrigin(kind: .microphone, name: "default input")
        }
        let name = string(id, kAudioObjectPropertyName) ?? "unnamed device"

        var details: [String] = []
        if let rate = nominalSampleRate(id) {
            details.append(String(format: "%.1f kHz", rate / 1000))
        }
        if let transport = transport(id) {
            details.append(transport)
        }
        return AudioOrigin(kind: .microphone, name: name, details: details)
    }

    // MARK: - CoreAudio

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The name comes back as a CFString the framework owns; taking it as Unmanaged and letting
        // ARC retain it is the documented dance, and skipping the retain is a use-after-free.
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    /// Why a device matters beyond its name: a Bluetooth headset in hands-free mode delivers 16 kHz
    /// mono through a codec that mangles the far field, and that is worth being able to see.
    private static func transport(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        default: return nil
        }
    }
}

#else

public enum AudioInputDevice {
    /// iOS has no notion of a user-chosen default input; the session decides, and the name is not
    /// knowable before capture. The app's screen will want the route name from `AVAudioSession`.
    public static func current() -> AudioOrigin {
        AudioOrigin(kind: .microphone, name: "microphone")
    }
}

#endif
