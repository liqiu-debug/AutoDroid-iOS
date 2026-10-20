import UserNotifications

@MainActor
final class CompletionNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CompletionNotifications()
    var onOpen: ((String) -> Void)?
    private var pending = Set<String>()
    private var sent = Set(UserDefaults.standard.stringArray(forKey: "completionNotifications") ?? [])

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
    func status() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional ? "AutoDroid 通知已允许" : "请允许 AutoDroid 发送通知"
    }
    func send(_ run: RunRecord) async throws -> Bool {
        guard !sent.contains(run.id), pending.insert(run.id).inserted else { return false }
        defer { pending.remove(run.id) }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = "AutoDroid · \(run.state)"
        content.body = run.name
        content.sound = .default
        content.userInfo = ["run_id": run.id]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id, content: content, trigger: nil))
        sent.insert(run.id)
        UserDefaults.standard.set(Array(sent), forKey: "completionNotifications")
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["run_id"] as? String
        Task { @MainActor in if let id { self.onOpen?(id) }; completionHandler() }
    }
}
