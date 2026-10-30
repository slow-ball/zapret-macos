import AppKit
import Foundation

/// Diagnostics and the fixes it offers
extension AppModel {
    func runDiagnostics() async {
        diagRunning = true
        diagError = nil
        var r = await Shell.run(["diag", "--tags"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["diag", "--tags"])
        }
        if r.out.isEmpty {
            diagError = r.err.isEmpty ? L("Диагностика не запустилась") : r.err
        }
        diagnostics = DiagSection.parse(r.out)
        diagRunning = false
    }
    static func fixTitle(_ code: String) -> String {
        switch code {
        case "start": L("Запустить")
        case "restart": L("Перезапустить")
        case "check": L("Подобрать стратегию")
        case "update": L("Обновить")
        case "telegram": L("Перезапустить прокси")
        case "smart": L("Включить умный режим")
        case "dns": L("Поставить DNS 1.1.1.1")
        case "proxy-settings": L("Настройки сети")
        case "monitor": L("Мониторинг системы")
        case "quit-flowseal": L("Закрыть TG WS Proxy")
        case "chrome-dns", "chrome-quic": L("Открыть в Chrome")
        case "relay": L("Настройки iCloud")
        default: L("Исправить")
        }
    }

    /// the buttons of the diagnostics: fixes zapret can do itself, or the right settings page
    func applyFix(_ code: String) async {
        let ws = NSWorkspace.shared
        func chrome(_ page: String) {
            guard let app = ws.urlForApplication(withBundleIdentifier: "com.google.Chrome"), let url = URL(string: page) else { return }
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
        switch code {
        case "start", "restart": await privileged(["start"], success: L("zapret перезапущен"))
        case "check": await runCheck(); return
        case "update": await update(); return
        case "telegram": await privileged(["telegram", "restart"], success: L("Прокси для Telegram перезапущен"))
        case "dns": await privileged(["dns"], success: L("DNS изменён"))
        case "smart": await privileged(["scope", "smart"], success: L("Включён умный режим"))
        case "proxy-settings": ws.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!); return
        case "monitor":
            if let app = ws.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            return
        case "quit-flowseal":
            ws.runningApplications.filter { $0.executableURL?.lastPathComponent == "TgWsProxy" }.forEach { $0.terminate() }
            try? await Task.sleep(for: .seconds(1))
        case "chrome-dns": chrome("chrome://settings/security"); return
        case "chrome-quic": chrome("chrome://flags/#enable-quic"); return
        case "relay": ws.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud")!); return
        default: return
        }
        await runDiagnostics()
    }
}
