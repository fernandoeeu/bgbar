import Foundation
import UserNotifications

/// Notificações de queda via UserNotifications.
/// Sem bundle (ex.: `swift run`) o UNUserNotificationCenter crasha, então tudo vira no-op.
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    private var enabled = false
    private var lastSent: [String: Date] = [:]
    private let minInterval: TimeInterval = 60

    private override init() { super.init() }

    /// Chamado uma vez no início do app.
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil, !enabled else { return }
        enabled = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `item` é o estado novo (caído); `previous` o estado anterior (no ar).
    func notifyDown(_ item: Item, previous: Item) {
        guard enabled else { return }
        let now = Date()
        if let last = lastSent[item.key], now.timeIntervalSince(last) < minInterval { return }
        lastSent[item.key] = now
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < minInterval }

        let content = UNMutableNotificationContent()
        content.title = title(item)
        content.body = body(item, previous: previous)
        content.sound = .default
        content.threadIdentifier = item.kind.rawValue

        let request = UNNotificationRequest(
            identifier: "down-\(item.key)-\(Int(now.timeIntervalSince1970))",
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func title(_ item: Item) -> String {
        switch item.status {
        case .unhealthy: "\(item.name) ficou unhealthy"
        case .restarting: "\(item.name) está reiniciando"
        case .failed: "\(item.name) falhou"
        case .notLoaded: "\(item.name) foi descarregado"
        default: "\(item.name) caiu"
        }
    }

    private func body(_ item: Item, previous: Item) -> String {
        let kind: String = switch item.kind {
        case .agent: "LaunchAgent"
        case .docker: "Docker"
        case .dev: "Processo de dev"
        }
        var parts = [kind, item.status.label]
        if let note = item.statusNote, !note.isEmpty {
            parts.append(note)
        } else if let code = item.exitCode {
            parts.append("exit \(code)")
        }
        if let up = previous.uptime { parts.append("estava no ar há \(Fmt.uptime(up))") }
        return parts.joined(separator: " · ")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Mostra banner mesmo com o app em primeiro plano.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
