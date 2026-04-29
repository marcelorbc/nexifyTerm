import Foundation
import UserNotifications
import AppKit

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    enum Category: String {
        case agentComplete = "AGENT_COMPLETE"
        case commandComplete = "COMMAND_COMPLETE"
    }

    enum Action: String {
        case viewResult = "VIEW_RESULT"
        case retry = "RETRY"
        case copyOutput = "COPY_OUTPUT"
    }

    var onViewResult: (() -> Void)?
    var onRetry: ((String) -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let viewAction = UNNotificationAction(
            identifier: Action.viewResult.rawValue,
            title: "Ver Resultado",
            options: [.foreground]
        )
        let retryAction = UNNotificationAction(
            identifier: Action.retry.rawValue,
            title: "Repetir",
            options: [.foreground]
        )
        let copyAction = UNNotificationAction(
            identifier: Action.copyOutput.rawValue,
            title: "Copiar Output",
            options: []
        )

        let agentCategory = UNNotificationCategory(
            identifier: Category.agentComplete.rawValue,
            actions: [viewAction, retryAction, copyAction],
            intentIdentifiers: [],
            options: []
        )

        let commandCategory = UNNotificationCategory(
            identifier: Category.commandComplete.rawValue,
            actions: [viewAction, copyAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([agentCategory, commandCategory])
    }

    func sendAgentComplete(
        summary: String,
        userInput: String,
        output: String = "",
        tabTitle: String? = nil,
        isError: Bool = false
    ) {
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = isError ? "Agente falhou" : "Agente finalizado"
        content.subtitle = tabTitle ?? "NexifyTerm"
        content.body = String(summary.prefix(200))
        content.sound = isError ? .defaultCritical : .default
        content.categoryIdentifier = Category.agentComplete.rawValue
        content.threadIdentifier = tabTitle ?? "main"
        content.userInfo = [
            "userInput": userInput,
            "output": String(output.prefix(4000))
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendCommandComplete(command: String, exitCode: Int32, output: String, tabTitle: String? = nil) {
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = exitCode == 0 ? "Comando concluído" : "Comando falhou (exit \(exitCode))"
        content.subtitle = tabTitle ?? "NexifyTerm"
        content.body = String(command.prefix(100))
        content.sound = exitCode == 0 ? .default : .defaultCritical
        content.categoryIdentifier = Category.commandComplete.rawValue
        content.threadIdentifier = tabTitle ?? "main"
        content.userInfo = ["output": String(output.prefix(4000))]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case Action.viewResult.rawValue, UNNotificationDefaultActionIdentifier:
            NSApp.activate(ignoringOtherApps: true)
            onViewResult?()

        case Action.retry.rawValue:
            if let input = userInfo["userInput"] as? String {
                NSApp.activate(ignoringOtherApps: true)
                onRetry?(input)
            }

        case Action.copyOutput.rawValue:
            if let output = userInfo["output"] as? String, !output.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }

        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
