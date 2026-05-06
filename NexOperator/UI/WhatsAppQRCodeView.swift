import SwiftUI
import AppKit

/// Minimal QR display that decodes a `data:image/png;base64,...` URL produced
/// by the Node bridge and renders it as a `NSImage`. The bridge regenerates
/// the QR every 30s if not scanned, so this view simply re-renders whenever
/// the store updates the URL.
struct WhatsAppQRCodeView: View {
    let dataURL: String
    let label: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Escaneie no WhatsApp")
                .font(.system(size: 14, weight: .semibold))

            if let image = decodedImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            } else {
                ProgressView()
                    .frame(width: 260, height: 260)
            }

            VStack(spacing: 4) {
                Text("Conectando \"\(label)\"")
                    .font(.system(size: 12, weight: .medium))
                Text("Abra WhatsApp > Configurações > Aparelhos conectados > Conectar um aparelho")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button("Cancelar", action: onCancel)
                .controlSize(.small)
        }
        .padding(20)
        .glassCard(cornerRadius: 12)
    }

    private var decodedImage: NSImage? {
        // The bridge always emits `data:image/png;base64,<payload>`; tolerate
        // a missing prefix in case the bridge ever returns raw base64.
        let payload = dataURL.split(separator: ",").last.map(String.init) ?? dataURL
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSImage(data: data)
    }
}
