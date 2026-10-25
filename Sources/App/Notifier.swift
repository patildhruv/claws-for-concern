import AppKit
import UserNotifications

/// Optional macOS notifications for new Clawds (off by default; Settings → Clawds). Clicking a
/// notification opens the session; seeing the session withdraws its notification.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func setUp() { center.delegate = self }

    func authorization(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { s in DispatchQueue.main.async { done(s.authorizationStatus) } }
    }

    func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    func post(_ a: Alert) {
        let c = UNMutableNotificationContent()
        c.title = a.title
        let state = BubbleView.stateWord(a)
        c.subtitle = state.prefix(1).uppercased() + state.dropFirst()
        c.body = a.recap
        c.userInfo = ["sid": a.sessionId]
        c.threadIdentifier = a.sessionId
        c.sound = nil  // the app's own sound setting decides
        center.add(UNNotificationRequest(identifier: "\(a.sessionId)@\(Int(a.ts))", content: c, trigger: nil))
    }

    /// Withdraw a session's notifications once you have seen it.
    func clear(_ sid: String) {
        center.getDeliveredNotifications { list in
            let ids = list.filter { ($0.request.content.userInfo["sid"] as? String) == sid }.map(\.request.identifier)
            if !ids.isEmpty { self.center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let sid = r.notification.request.content.userInfo["sid"] as? String {
            DispatchQueue.main.async { self.onOpen?(sid) }
        }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }
}
