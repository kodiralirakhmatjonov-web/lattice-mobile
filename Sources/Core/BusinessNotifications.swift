import Foundation
import UIKit
import UserNotifications

@MainActor
final class BusinessAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "iumrah.push.deviceToken")
        UserDefaults.standard.removeObject(forKey: "iumrah.push.lastRegistrationError")
        Task {
            _ = try? await APIClient.shared.registerPushDevice(token: token, environment: "production")
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(error.localizedDescription, forKey: "iumrah.push.lastRegistrationError")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge, .list])
    }
}

enum BusinessNotifications {
    private static let trackedJobsKey = "iumrah.notifications.trackedHotelImportJobs.v1"
    private static let notifiedJobsKey = "iumrah.notifications.notifiedHotelImportJobs.v1"

    static func prepare() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard granted else { return }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await registerCurrentDeviceIfPossible()
    }

    static func registerCurrentDeviceIfPossible() async {
        guard let token = UserDefaults.standard.string(forKey: "iumrah.push.deviceToken"), !token.isEmpty else { return }
        do {
            _ = try await APIClient.shared.registerPushDevice(token: token, environment: "production")
            UserDefaults.standard.removeObject(forKey: "iumrah.push.lastRegistrationError")
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "iumrah.push.lastRegistrationError")
        }
    }

    static func hotelImportStarted(_ job: HotelImportJob) async {
        var tracked = storedIDs(forKey: trackedJobsKey)
        tracked.insert(job.id)
        saveIDs(tracked, forKey: trackedJobsKey)
    }

    static func trackActiveHotelImports(_ jobs: [HotelImportJob]) async {
        var tracked = storedIDs(forKey: trackedJobsKey)
        for job in jobs where job.isActive { tracked.insert(job.id) }
        saveIDs(tracked, forKey: trackedJobsKey)
    }

    /// Server-side imports keep running independently. This local reconciliation is
    /// retained as a safe fallback until APNs credentials + entitlement are active.
    static func notifyUnseenTerminalJobs(_ jobs: [HotelImportJob]) async {
        var tracked = storedIDs(forKey: trackedJobsKey)
        var notified = storedIDs(forKey: notifiedJobsKey)
        var changed = false
        for job in jobs where !job.isActive {
            guard tracked.contains(job.id), !notified.contains(job.id) else { continue }
            await deliver(job)
            notified.insert(job.id)
            tracked.remove(job.id)
            changed = true
        }
        if changed {
            saveIDs(tracked, forKey: trackedJobsKey)
            saveIDs(notified, forKey: notifiedJobsKey)
        }
    }

    static func hotelImportFinished(_ job: HotelImportJob) async {
        await deliver(job)
        var notified = storedIDs(forKey: notifiedJobsKey)
        notified.insert(job.id)
        saveIDs(notified, forKey: notifiedJobsKey)
        var tracked = storedIDs(forKey: trackedJobsKey)
        tracked.remove(job.id)
        saveIDs(tracked, forKey: trackedJobsKey)
    }

    private static func deliver(_ job: HotelImportJob) async {
        let content = UNMutableNotificationContent()
        content.title = job.isCompleted ? "Импорт отеля завершён" : "Импорт отеля требует внимания"
        if job.isCompleted {
            content.body = "\(job.hotelName) · \(job.storedImages) фото сохранено в iumrah Hotels."
        } else {
            content.body = job.error ?? "\(job.hotelName) сохранён как черновик. Проверьте импорт."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "iumrah.hotel.\(job.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func storedIDs(forKey key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func saveIDs(_ values: Set<String>, forKey key: String) {
        UserDefaults.standard.set(Array(values.suffix(250)), forKey: key)
    }
}
