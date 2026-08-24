import Foundation
import UserNotifications

enum BusinessNotifications {
    private static let trackedJobsKey = "iumrah.notifications.trackedHotelImportJobs.v1"
    private static let notifiedJobsKey = "iumrah.notifications.notifiedHotelImportJobs.v1"

    static func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
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

    /// Reconciles server-side jobs after foreground/relaunch. This is intentionally
    /// not presented as APNs: the Cloudflare job keeps running while iOS is closed,
    /// then the app surfaces any tracked terminal result the next time it can run.
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
        // Bound local bookkeeping; the server remains the source of truth for jobs.
        UserDefaults.standard.set(Array(values.suffix(250)), forKey: key)
    }
}
