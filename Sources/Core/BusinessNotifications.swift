import Foundation
import UserNotifications

enum BusinessNotifications {
    static func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    static func hotelImportFinished(_ job: HotelImportJob) async {
        let content = UNMutableNotificationContent()
        content.title = job.isCompleted ? "Отель добавлен" : "Импорт отеля требует внимания"
        if job.isCompleted {
            content.body = "\(job.hotelName) · \(job.storedImages) фото сохранено в iumrah Hotels."
        } else {
            content.body = job.error ?? "\(job.hotelName) сохранён как черновик. Проверьте импорт."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "iumrah.hotel.\(job.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
