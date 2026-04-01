import os

enum AppLogger {
    static let data = Logger(subsystem: "ru.akifi.app", category: "DataStore")
    static let ai = Logger(subsystem: "ru.akifi.app", category: "AI")
    static let auth = Logger(subsystem: "ru.akifi.app", category: "Auth")
    static let network = Logger(subsystem: "ru.akifi.app", category: "Network")
    static let notifications = Logger(subsystem: "ru.akifi.app", category: "Notifications")
}
