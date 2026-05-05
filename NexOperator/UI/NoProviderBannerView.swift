import SwiftUI

struct NoProviderBannerView: View {
    @ObservedObject private var availability = ProviderAvailabilityService.shared
    var onOpenSettings: () -> Void

    var body: some View {
        if availability.hasChecked && !availability.hasAnyProvider {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)

                    Text("Nenhum provedor de IA configurado")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)

                    Text("Sem um provedor ativo, o agente de IA não pode gerar planos, executar comandos inteligentes ou responder perguntas. Configure ao menos uma opção para desbloquear todo o potencial do NexifyTerm.")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                VStack(alignment: .leading, spacing: 8) {
                    providerRow(
                        icon: "shippingbox",
                        color: .green,
                        title: "Ollama (Local — Gratuito)",
                        subtitle: "Rode modelos localmente com total privacidade. Requer Ollama instalado e rodando.",
                        isAvailable: availability.ollamaAvailable
                    )
                    providerRow(
                        icon: "key.fill",
                        color: .blue,
                        title: "OpenAI",
                        subtitle: "GPT-5.5, GPT-4o e mais. Requer chave de API.",
                        isAvailable: availability.openAIAvailable
                    )
                    providerRow(
                        icon: "key.fill",
                        color: .purple,
                        title: "Google Gemini",
                        subtitle: "Gemini 2.5 Pro com 1M de contexto. Requer chave de API.",
                        isAvailable: availability.geminiAvailable
                    )
                }
                .frame(maxWidth: 420)

                HStack(spacing: 12) {
                    Button {
                        onOpenSettings()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12))
                            Text("Configurar Provedores")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(NexTheme.accent)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await availability.refresh() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("Verificar novamente")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }

    private func providerRow(icon: String, color: Color, title: String, subtitle: String, isAvailable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(NexTheme.textPrimary)
                    if isAvailable {
                        Text("Ativo")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.green))
                    } else {
                        Text("Não configurado")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isAvailable ? Color.green.opacity(0.04) : Color.orange.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isAvailable ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}
