import Foundation
import CoreAudio
import AVFoundation

/// Inspeciona o roteamento atual de áudio do macOS via Core Audio para
/// detectar situações que sabotam silenciosamente a captura via
/// ScreenCaptureKit — em especial, dispositivos Bluetooth (AirPods, headsets)
/// que entram em modo HFP/SCO assim que algum mic Bluetooth é ativado.
///
/// Sintoma típico que isso resolve: usuário tenta gravar "mic + áudio do
/// sistema" com AirPods conectados, o microfone dos AirPods força A2DP→HFP,
/// e o output Bluetooth deixa de passar pelo mixer interno do CoreAudio que
/// o `SCStream(capturesAudio:)` consome — resultado é arquivo de áudio do
/// sistema vazio, sem nenhum erro reportado.
enum AudioRouteInspector {

    struct Route {
        let outputDeviceName: String
        let outputTransport: Transport
        let inputDeviceName: String?
        let inputTransport: Transport?

        /// `true` quando o output ativo é Bluetooth — risco alto de o
        /// `ScreenCaptureKit` perder samples assim que um mic Bluetooth
        /// for ativado em paralelo (driver troca pra HFP/SCO).
        var outputIsBluetooth: Bool { outputTransport == .bluetooth }

        /// `true` quando o mic escolhido pertence a um dispositivo Bluetooth
        /// — ativá-lo causa o "audio ducking" típico (volume parece subir,
        /// qualidade cai) e geralmente quebra a captura do sistema.
        var inputIsBluetooth: Bool { inputTransport == .bluetooth }
    }

    enum Transport: String {
        case builtIn
        case usb
        case bluetooth
        case airplay
        case hdmi
        case displayPort
        case thunderbolt
        case aggregate
        case virtual
        case other
        case unknown

        var humanLabel: String {
            switch self {
            case .builtIn:     return "interno"
            case .usb:         return "USB"
            case .bluetooth:   return "Bluetooth"
            case .airplay:     return "AirPlay"
            case .hdmi:        return "HDMI"
            case .displayPort: return "DisplayPort"
            case .thunderbolt: return "Thunderbolt"
            case .aggregate:   return "agregado"
            case .virtual:     return "virtual"
            case .other:       return "outro"
            case .unknown:     return "desconhecido"
            }
        }
    }

    /// Tira um snapshot do roteamento atual. Retorna `nil` apenas em falha
    /// catastrófica do Core Audio (não deve acontecer em condições normais).
    static func currentRoute() -> Route? {
        guard let outID = defaultDeviceID(scope: kAudioObjectPropertyScopeOutput) else {
            return nil
        }
        let outName = deviceName(outID) ?? "Saída"
        let outTransport = transport(of: outID)

        let inID = defaultDeviceID(scope: kAudioObjectPropertyScopeInput)
        let inName = inID.flatMap { deviceName($0) }
        let inTransport = inID.map { transport(of: $0) }

        return Route(
            outputDeviceName: outName,
            outputTransport: outTransport,
            inputDeviceName: inName,
            inputTransport: inTransport
        )
    }

    /// Detecta se o microfone selecionado pelo usuário pertence a um
    /// dispositivo Bluetooth — independente do que o sistema considera
    /// "default input". Usado pelo gravador para alertar o usuário antes
    /// de iniciar uma sessão "mic + system audio" que vai quebrar.
    static func isBluetoothMic(_ device: AVCaptureDevice) -> Bool {
        guard let coreAudioID = coreAudioID(for: device) else { return false }
        return transport(of: coreAudioID) == .bluetooth
    }

    // MARK: - Core Audio helpers

    private static func defaultDeviceID(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        let selector = (scope == kAudioObjectPropertyScopeOutput)
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultInputDevice

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id
        )
        guard status == noErr, id != 0 else { return nil }
        return id
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func transport(of id: AudioDeviceID) -> Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw)
        guard status == noErr else { return .unknown }

        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:     return .builtIn
        case kAudioDeviceTransportTypeUSB:         return .usb
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay:     return .airplay
        case kAudioDeviceTransportTypeHDMI:        return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual:     return .virtual
        default:                                    return .other
        }
    }

    /// Mapeia um `AVCaptureDevice` (ID opaco do AVFoundation) para o
    /// `AudioDeviceID` correspondente em Core Audio, escaneando todos os
    /// dispositivos do sistema e comparando UID.
    private static func coreAudioID(for device: AVCaptureDevice) -> AudioDeviceID? {
        let targetUID = device.uniqueID

        var sizeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &sizeAddress, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &sizeAddress, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for id in devices where deviceUID(id) == targetUID {
            return id
        }
        return nil
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
