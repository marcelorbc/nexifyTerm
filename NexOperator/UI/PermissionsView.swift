import SwiftUI

struct PermissionsView: View {
    @ObservedObject var manager: PermissionsManager
    let onComplete: () -> Void

    @State private var isRequestingAll = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)

                    Text("Bem-vindo ao NexOperator")
                        .font(.title2.bold())
                        .foregroundColor(NexTheme.textPrimary)

                    Text("Para funcionar como um terminal completo sem interrupções, o app precisa de acesso total ao sistema — como o Finder.")
                        .font(.callout)
                        .foregroundColor(NexTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                if !allGranted && !isRequestingAll {
                    Button {
                        isRequestingAll = true
                        Task {
                            await manager.requestAllAutomatic()
                            isRequestingAll = false
                        }
                    } label: {
                        Label("Liberar Tudo de Uma Vez", systemImage: "bolt.shield.fill")
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if isRequestingAll {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Solicitando permissões...")
                            .font(.caption)
                            .foregroundColor(NexTheme.textSecondary)
                    }
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.permissions) { item in
                            PermissionRowView(item: item) {
                                handleAction(item)
                            }
                        }
                    }
                }
                .frame(maxWidth: 440, maxHeight: 320)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(grantedCount)/\(manager.permissions.count) permissões")
                            .font(.caption)
                            .foregroundColor(NexTheme.textSecondary)

                        progressBar
                    }
                    .frame(maxWidth: 260)

                    Button {
                        manager.markOnboardingComplete()
                        onComplete()
                    } label: {
                        Text(allGranted ? "Começar a usar" : "Continuar mesmo assim")
                            .frame(maxWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(allGranted ? NexTheme.accent : .secondary)

                    if !allGranted {
                        Text("Permissões manuais podem ser configuradas em Ajustes do Sistema > Privacidade")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }

                    Button("Verificar novamente") {
                        Task { await manager.refreshStatuses() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allGranted: Bool {
        manager.permissions.allSatisfy { $0.status == .granted }
    }

    private var grantedCount: Int {
        manager.permissions.filter { $0.status == .granted }.count
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(NexTheme.surface)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: manager.permissions.isEmpty ? 0 : geo.size.width * CGFloat(grantedCount) / CGFloat(manager.permissions.count), height: 6)
                    .animation(.easeInOut(duration: 0.3), value: grantedCount)
            }
        }
        .frame(height: 6)
    }

    private func handleAction(_ item: PermissionItem) {
        switch item.id {
        case "notifications":
            Task { await manager.requestNotifications() }
        case "accessibility":
            manager.openAccessibilitySettings()
        case "fullDiskAccess":
            manager.openFullDiskAccessSettings()
        case "automation":
            manager.triggerAutomationPermission()
        case "contacts":
            Task { await manager.requestContacts() }
        case "calendar":
            Task { await manager.requestCalendar() }
        case "location":
            Task { await manager.requestLocation() }
        case "photos":
            Task { await manager.requestPhotos() }
        default:
            break
        }
    }
}

struct PermissionRowView: View {
    let item: PermissionItem
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16))
                .foregroundColor(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                Text(item.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusBadge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusBorderColor, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .granted:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                Text("OK")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.green)

        case .denied:
            Button { onAction() } label: {
                Text(item.isManual ? "Abrir Config." : "Permitir")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(NexTheme.accent.opacity(0.15))
                    .foregroundColor(NexTheme.accent)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)

        case .notDetermined:
            Button { onAction() } label: {
                Text(item.isManual ? "Abrir Config." : "Permitir")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .granted: return .green
        case .denied: return .orange
        case .notDetermined: return NexTheme.accent
        }
    }

    private var statusBorderColor: Color {
        switch item.status {
        case .granted: return .green.opacity(0.2)
        case .denied: return .orange.opacity(0.2)
        case .notDetermined: return .secondary.opacity(0.1)
        }
    }
}
