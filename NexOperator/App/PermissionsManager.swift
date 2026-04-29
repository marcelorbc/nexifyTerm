import Foundation
import AppKit
import UserNotifications
import ApplicationServices
import CoreLocation
import Contacts
import EventKit
import Photos

enum PermissionStatus: String {
    case granted = "granted"
    case denied = "denied"
    case notDetermined = "notDetermined"
}

struct PermissionItem: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String
    var status: PermissionStatus
    let isManual: Bool
}

class PermissionsManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var permissions: [PermissionItem] = []
    @Published var hasChecked = false

    static let hasCompletedOnboardingKey = "hasCompletedPermissionsOnboarding"

    private lazy var locationManager: CLLocationManager = {
        let lm = CLLocationManager()
        lm.delegate = self
        return lm
    }()

    private var locationContinuation: CheckedContinuation<PermissionStatus, Never>?

    var needsOnboarding: Bool {
        !NexPersistence.shared.getFlag(Self.hasCompletedOnboardingKey)
    }

    func markOnboardingComplete() {
        NexPersistence.shared.setFlag(Self.hasCompletedOnboardingKey, value: true)
    }

    @MainActor
    func checkAllPermissions() async {
        var items: [PermissionItem] = []

        let notifStatus = await checkNotificationPermission()
        items.append(PermissionItem(
            id: "notifications",
            name: "Notificações",
            description: "Avisar quando o agente terminar em background",
            icon: "bell.badge",
            status: notifStatus,
            isManual: false
        ))

        let accessibilityStatus = checkAccessibilityPermission()
        items.append(PermissionItem(
            id: "accessibility",
            name: "Acessibilidade",
            description: "Enviar comandos ao terminal e capturar atalhos globais",
            icon: "hand.raised",
            status: accessibilityStatus,
            isManual: true
        ))

        let fdaStatus = checkFullDiskAccess()
        items.append(PermissionItem(
            id: "fullDiskAccess",
            name: "Acesso Total ao Disco",
            description: "Ler e gravar qualquer arquivo do sistema, como o Finder",
            icon: "internaldrive",
            status: fdaStatus,
            isManual: true
        ))

        let automationStatus = checkAutomationPermission()
        items.append(PermissionItem(
            id: "automation",
            name: "Automação (Apple Events)",
            description: "Controlar outros apps: Finder, Safari, Terminal, System Preferences",
            icon: "gearshape.2",
            status: automationStatus,
            isManual: true
        ))

        let contactsStatus = checkContactsPermission()
        items.append(PermissionItem(
            id: "contacts",
            name: "Contatos",
            description: "Acessar contatos para automações e scripts do sistema",
            icon: "person.crop.circle",
            status: contactsStatus,
            isManual: false
        ))

        let calendarStatus = checkCalendarPermission()
        items.append(PermissionItem(
            id: "calendar",
            name: "Calendário",
            description: "Acessar calendários para automações e scripts do sistema",
            icon: "calendar",
            status: calendarStatus,
            isManual: false
        ))

        let locationStatus = checkLocationPermission()
        items.append(PermissionItem(
            id: "location",
            name: "Localização",
            description: "Identificar rede, fuso horário e configurações regionais",
            icon: "location",
            status: locationStatus,
            isManual: false
        ))

        let photosStatus = checkPhotosPermission()
        items.append(PermissionItem(
            id: "photos",
            name: "Fotos",
            description: "Acessar biblioteca de fotos para operações do sistema",
            icon: "photo.on.rectangle",
            status: photosStatus,
            isManual: false
        ))

        items.append(PermissionItem(
            id: "systemAdmin",
            name: "Administração do Sistema",
            description: "Executar comandos sudo e alterar configurações do sistema",
            icon: "lock.shield",
            status: .granted,
            isManual: false
        ))

        permissions = items
        hasChecked = true
    }

    /// Requests all auto-requestable permissions at once
    func requestAllAutomatic() async {
        await requestNotifications()
        await requestContacts()
        await requestCalendar()
        await requestLocation()
        await requestPhotos()
        triggerAutomationPermission()
    }

    // MARK: - Individual Requests

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                updateStatus("notifications", status: granted ? .granted : .denied)
            }
        } catch {
            await MainActor.run {
                updateStatus("notifications", status: .denied)
            }
        }
    }

    func requestContacts() async {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            await MainActor.run {
                updateStatus("contacts", status: granted ? .granted : .denied)
            }
        } catch {
            await MainActor.run {
                updateStatus("contacts", status: .denied)
            }
        }
    }

    func requestCalendar() async {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            await MainActor.run {
                updateStatus("calendar", status: granted ? .granted : .denied)
            }
        } catch {
            await MainActor.run {
                updateStatus("calendar", status: .denied)
            }
        }
    }

    func requestLocation() async {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionStatus, Never>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .denied)
                    return
                }
                let current = self.locationManager.authorizationStatus
                if current == .notDetermined {
                    self.locationContinuation = continuation
                    self.locationManager.requestWhenInUseAuthorization()
                } else {
                    let s: PermissionStatus = (current == .authorizedAlways || current == .authorized) ? .granted : .denied
                    continuation.resume(returning: s)
                }
            }
        }
        await MainActor.run {
            updateStatus("location", status: status)
        }
    }

    func requestPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let permStatus: PermissionStatus = (status == .authorized || status == .limited) ? .granted : .denied
        await MainActor.run {
            updateStatus("photos", status: permStatus)
        }
    }

    func triggerAutomationPermission() {
        DispatchQueue.global(qos: .utility).async {
            let script = NSAppleScript(source: """
                tell application "System Events"
                    return name of first process
                end tell
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            DispatchQueue.main.async { [weak self] in
                let granted = error == nil
                self?.updateStatus("automation", status: granted ? .granted : .denied)
            }
        }
    }

    // MARK: - Open System Settings

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    func openPrivacySettings(for anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Refresh

    @MainActor
    func refreshStatuses() async {
        let notifStatus = await checkNotificationPermission()
        updateStatus("notifications", status: notifStatus)

        updateStatus("accessibility", status: checkAccessibilityPermission())
        updateStatus("fullDiskAccess", status: checkFullDiskAccess())
        updateStatus("automation", status: checkAutomationPermission())
        updateStatus("contacts", status: checkContactsPermission())
        updateStatus("calendar", status: checkCalendarPermission())
        updateStatus("location", status: checkLocationPermission())
        updateStatus("photos", status: checkPhotosPermission())
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        let permStatus: PermissionStatus = (status == .authorizedAlways || status == .authorized) ? .granted : .denied
        locationContinuation?.resume(returning: permStatus)
        locationContinuation = nil
    }

    // MARK: - Private Checks

    private func checkNotificationPermission() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }

    private func checkAccessibilityPermission() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func checkFullDiskAccess() -> PermissionStatus {
        let testPath = NSHomeDirectory() + "/Library/Mail"
        let accessible = FileManager.default.isReadableFile(atPath: testPath)
        return accessible ? .granted : .denied
    }

    private func checkAutomationPermission() -> PermissionStatus {
        let script = NSAppleScript(source: """
            tell application "System Events"
                return name of first process
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil ? .granted : .notDetermined
    }

    private func checkContactsPermission() -> PermissionStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func checkCalendarPermission() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func checkLocationPermission() -> PermissionStatus {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    private func checkPhotosPermission() -> PermissionStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        default: return .notDetermined
        }
    }

    @MainActor
    private func updateStatus(_ id: String, status: PermissionStatus) {
        if let idx = permissions.firstIndex(where: { $0.id == id }) {
            permissions[idx].status = status
        }
    }
}
