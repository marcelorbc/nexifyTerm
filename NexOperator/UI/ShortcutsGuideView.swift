import SwiftUI

struct ShortcutsGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            shortcutSection("Abas", icon: "rectangle.stack", shortcuts: [
                ("⌘ T", "Novo terminal"),
                ("⌘ ⇧ E", "Novo explorer"),
                ("⌘ W", "Fechar aba ativa"),
                ("⌘ 1–9", "Ir para a aba pelo número"),
                ("⌘ ⇧ ]", "Próxima aba"),
                ("⌘ ⇧ [", "Aba anterior"),
                ("⌥ ⌘ →", "Próxima aba"),
                ("⌥ ⌘ ←", "Aba anterior"),
                ("⌃ Tab", "Próxima aba"),
                ("⌃ ⇧ Tab", "Aba anterior"),
            ])

            shortcutSection("Painéis", icon: "sidebar.left", shortcuts: [
                ("⌘ B", "Alternar sidebar (file browser)"),
                ("⌘ Y", "Alternar painel de histórico"),
            ])

            shortcutSection("Foco & Edição", icon: "text.cursor", shortcuts: [
                ("⌘ L", "Focar no campo de input"),
                ("⏎ (Return)", "Enviar comando / prompt"),
                ("⇧ ⏎", "Nova linha no campo de input"),
                ("↑ / ↓", "Navegar histórico de comandos no input"),
                ("Esc", "Limpar input / fechar popup"),
            ])

            shortcutSection("Fonte", icon: "textformat.size", shortcuts: [
                ("⌘ +", "Aumentar fonte do terminal"),
                ("⌘ -", "Diminuir fonte do terminal"),
                ("⌘ 0", "Restaurar tamanho padrão"),
            ])

            shortcutSection("App", icon: "gear", shortcuts: [
                ("⌘ ,", "Abrir configurações"),
            ])

            Divider()
                .padding(.vertical, 4)

            featureSection("Funcionalidades", icon: "sparkles", features: [
                ("Terminal inteligente", "Terminal nativo com integração de IA para executar comandos via linguagem natural."),
                ("Explorer de arquivos", "Navegue por pastas e arquivos em abas dedicadas, com preview e ações de contexto."),
                ("Agente de IA", "Descreva o que precisa e o agente planeja e executa os comandos automaticamente."),
                ("Múltiplos provedores", "Suporte a Ollama (local), OpenAI e Gemini com seleção por aba."),
                ("Histórico de sessão", "Consulte comandos e execuções anteriores no painel lateral."),
                ("Skills personalizados", "Crie e gerencie skills que expandem o comportamento do agente."),
                ("MCP Servers", "Conecte servidores MCP para ferramentas externas disponíveis ao agente."),
                ("Browser integrado", "O agente pode abrir e interagir com páginas web dentro do app."),
                ("Plano de execução", "Visualize e aprove o plano antes da execução com modo de aprovação configurável."),
                ("Drag & drop de arquivos", "Arraste arquivos para o input para enviar como contexto ao agente."),
                ("Sidebar de arquivos", "Barra lateral para navegar o sistema de arquivos rapidamente."),
            ])
        }
    }

    private func shortcutSection(_ title: String, icon: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
            }

            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    HStack {
                        Text(shortcut.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(NexTheme.accent)
                            .frame(width: 100, alignment: .leading)

                        Text(shortcut.1)
                            .font(.system(size: 12))
                            .foregroundColor(NexTheme.textSecondary)

                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(index.isMultiple(of: 2) ? Color.clear : NexTheme.surface.opacity(0.4))
                }
            }
            .background(NexTheme.surface.opacity(0.2))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(NexTheme.border.opacity(0.4), lineWidth: 0.5)
            )
        }
    }

    private func featureSection(_ title: String, icon: String, features: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.0)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(NexTheme.textPrimary)

                        Text(feature.1)
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.clear : NexTheme.surface.opacity(0.4))
                }
            }
            .background(NexTheme.surface.opacity(0.2))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(NexTheme.border.opacity(0.4), lineWidth: 0.5)
            )
        }
    }
}
