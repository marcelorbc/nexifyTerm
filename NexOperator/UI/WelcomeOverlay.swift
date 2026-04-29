import SwiftUI

struct WelcomeOverlay: View {
    let onPrompt: (String) -> Void
    let onDismiss: () -> Void

    private let examples: [(icon: String, text: String, prompt: String)] = [
        ("speedometer", "Meu Mac está lento, me ajuda", "my Mac feels slow, diagnose the issue: check CPU, memory, disk I/O, and top processes"),
        ("bolt.circle", "Quem está usando a porta 3000?", "check which process is using port 3000 and show details"),
        ("internaldrive", "Mostrar arquivos grandes no disco", "find the largest files and folders on my disk and help me understand what's taking space"),
        ("wifi", "Verificar minha conexão", "test my internet connection, show my IP, DNS, and ping results"),
        ("trash.circle", "Limpar caches com segurança", "find safe caches and temporary files I can clean to free up disk space, show sizes"),
        ("arrow.up.circle", "Apps que iniciam no login", "list all login items and startup apps, show how to disable the ones I don't need"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "sparkles")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.accentColor, .accentColor.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                    Text("NexOperator")
                        .font(.system(size: 26, weight: .bold, design: .rounded))

                    Text("Digite um comando ou pergunte em linguagem natural")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 10) {
                    Text("EXPERIMENTE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.7))
                        .tracking(2)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(examples, id: \.text) { example in
                            Button {
                                onPrompt(example.prompt)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: example.icon)
                                        .font(.system(size: 12))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 18)
                                    Text(example.text)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .glassCard(cornerRadius: 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 520)
                }

                Button {
                    onDismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                        Text("Ir para o terminal")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                Capsule()
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
        .background(.ultraThickMaterial)
    }
}
