import Foundation
import AVFoundation

/// Representa um microfone disponível no sistema (built-in, USB, AirPods, agregado, etc).
struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String?
    let isBuiltIn: Bool

    init(captureDevice: AVCaptureDevice) {
        self.id = captureDevice.uniqueID
        self.name = captureDevice.localizedName
        self.manufacturer = captureDevice.manufacturer
        self.isBuiltIn = captureDevice.deviceType == .builtInMicrophone
    }
}

enum AudioInputDevices {

    /// Lista todos os microfones disponíveis. Sempre inclui o microfone padrão
    /// como primeira entrada (útil quando ainda não há ID salvo nas preferências).
    static func list() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes(),
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map(AudioInputDevice.init)
    }

    /// Procura um dispositivo pelo ID persistido. Retorna `nil` se não estiver
    /// mais conectado.
    static func device(withID id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }

    /// Microfone padrão escolhido pelo sistema (preferência do usuário em "Sound").
    static func systemDefault() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio)
    }

    /// Resolve o dispositivo a usar dado o ID salvo: tenta o ID, depois o default,
    /// depois qualquer um da lista.
    static func resolve(preferredID: String?) -> AVCaptureDevice? {
        if let id = preferredID, let device = device(withID: id) {
            return device
        }
        if let def = systemDefault() { return def }
        return list().first.flatMap { device(withID: $0.id) }
    }

    private static func deviceTypes() -> [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.microphone)
        }
        return types
    }
}
