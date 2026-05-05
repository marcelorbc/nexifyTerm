import SwiftUI

struct ModelSelectorView: View {
    @Binding var tab: TerminalTab

    private var currentCaps: ModelCapabilities {
        ProviderType.capabilities(for: tab.model)
    }

    var body: some View {
        let availability = ProviderAvailabilityService.shared
        let providers = availability.availableProviders.isEmpty
            ? ProviderType.allCases
            : availability.availableProviders
        let models = availability.availableModels(for: tab.provider)

        HStack(spacing: 8) {
            Picker("", selection: $tab.provider) {
                ForEach(providers) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .frame(width: 90)
            .controlSize(.small)
            .onChange(of: tab.provider) { _, newProvider in
                let newModels = availability.availableModels(for: newProvider)
                tab.model = newModels.first ?? newProvider.defaultModel
            }

            Picker("", selection: $tab.model) {
                ForEach(models, id: \.self) { model in
                    let caps = ProviderType.capabilities(for: model)
                    Label(model, systemImage: caps.tier.icon)
                        .tag(model)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .controlSize(.small)

            capabilityBadges

            Picker("", selection: $tab.approvalMode) {
                ForEach(ApprovalMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var capabilityBadges: some View {
        HStack(spacing: 3) {
            tierBadge

            if currentCaps.supportsToolCalling {
                badgeIcon("wrench.fill", color: .blue, tooltip: "Tool Calling")
            }
            if currentCaps.canReadFiles {
                badgeIcon("doc.text.fill", color: .green, tooltip: "Acesso a Arquivos")
            }
            if currentCaps.supportsReasoning {
                badgeIcon("brain", color: .purple, tooltip: "Raciocínio")
            }
        }
    }

    private var tierBadge: some View {
        let color: Color = switch currentCaps.tier {
        case .pro:      .orange
        case .standard: .blue
        case .lite:     .gray
        case .local:    .green
        }

        return Text(currentCaps.tier.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.15))
            )
            .help(currentCaps.description)
    }

    private func badgeIcon(_ systemName: String, color: Color, tooltip: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8))
            .foregroundColor(color.opacity(0.8))
            .help(tooltip)
    }
}
