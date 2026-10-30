import AppKit
import Carbon
import UserNotifications

/// zapret://toggle, zapret://start, zapret://stop, zapret://check — for the widget and anything else
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// opened by the user, not by the login item at startup
    private var openedByUser = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        openedByUser = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem
    }

    /// opened from Finder, Launchpad or Spotlight: show the window, like any app. At login only the icon
    private func showWindowSoon() {
        guard Snapshot.folder == nil else { return }
        // the menu bar icon hands over the way to open the window once it appears
        Task { @MainActor in
            for _ in 0..<20 {
                if let open = AppModel.shared.openMainWindow { open(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// opening the app again while it runs (Finder, Dock) brings the window back
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindowSoon() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if openedByUser { showWindowSoon() }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        Notifier.setUp(delegate: self)
        HotKey.shared.update()
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        Task { @MainActor in
            let model = AppModel.shared
            switch url.host {
            case "toggle": await model.toggle()
            case "start": if !model.status.running { await model.toggle() }
            case "stop": if model.status.running { await model.toggle() }
            case "check": await model.runCheck()
            case "open": model.openMainWindow?()
            default: break
            }
        }
    }

    // notifications: show them while the app is in front too, and handle their buttons
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in
            let model = AppModel.shared
            switch action {
            case Notifier.start: if !model.status.running { await model.toggle() }
            case Notifier.check: await model.runCheck()
            case Notifier.update: await model.update()
            default: break
            }
            completion()
        }
    }
}

enum Notifier {
    static let start = "start", check = "check", update = "update"

    /// notifications need a real app bundle: a bare binary (development) would crash
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "stopped", actions: [UNNotificationAction(identifier: start, title: L("Включить"))],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "broken", actions: [UNNotificationAction(identifier: check, title: L("Подобрать стратегию"))],
                intentIdentifiers: []),
            UNNotificationCategory(
                identifier: "update", actions: [UNNotificationAction(identifier: update, title: L("Обновить"))],
                intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String, category: String? = nil) {
        guard Snapshot.folder == nil, available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// ⌃⌥Z switches zapret on and off from anywhere. Carbon hot keys need no accessibility permission
final class HotKey {
    static let shared = HotKey()
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkey") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hotkey"); shared.update() }
    }

    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func update() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard HotKey.enabled else { return }
        if !handlerInstalled {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    Task { @MainActor in await AppModel.shared.toggle() }
                    return noErr
                }, 1, &type, nil, nil)
            handlerInstalled = true
        }
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Z), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x7A617074, id: 1),
            GetApplicationEventTarget(), 0, &ref)
    }
}
