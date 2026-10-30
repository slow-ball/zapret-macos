import AppKit
import Foundation
import ServiceManagement

/// Installing and removing zapret from the app
extension AppModel {
    /// back to how zapret starts out (zapret.sh reset): the user's lists and the switches stay
    func resetZapret() async {
        await privileged(["reset"], success: L("zapret сброшен"))
        check = nil
        deep = nil
        siteResult = nil
        await refresh()
    }

    /// installs without Terminal: the project from inside the app goes to ~/zapret-macos
    /// (unless it is there already), then its installer runs with the password dialog
    func installZapret() async {
        installing = true
        installError = nil
        defer { installing = false }
        let dest = NSHomeDirectory() + "/zapret-macos"
        if !FileManager.default.fileExists(atPath: dest + "/src/zapret.sh") {
            guard let payload = Bundle.main.resourcePath.map({ $0 + "/project" }),
                FileManager.default.fileExists(atPath: payload)
            else {
                installError = L("В приложении нет файлов проекта")
                return
            }
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [payload, dest]
            try? copy.run()
            copy.waitUntilExit()
            guard copy.terminationStatus == 0 else {
                installError = L("Не удалось скопировать файлы в \(dest)")
                return
            }
        }
        let r = await Shell.admin(dest + "/src/zapret.sh", ["install", "--no-app"])
        if r.ok {
            await refresh()
            show(L("zapret установлен"))
        } else if !r.err.contains("-128") && !r.err.localizedCaseInsensitiveContains("cancel") {
            installError = r.err.isEmpty ? L("Установка не удалась") : r.err
        }
    }

    /// removes zapret itself (with the password dialog: irreversible, so never passwordless);
    /// with everything, the app and the project folder go to the Trash too
    func uninstallZapret(everything: Bool) async {
        busy = true
        let r = await Shell.admin(Shell.script, ["uninstall", "--yes"])
        busy = false
        guard r.ok else {
            if !r.err.contains("-128") { show(r.err.isEmpty ? L("Не удалось удалить") : r.err) }
            return
        }
        try? await SMAppService.mainApp.unregister()
        if everything {
            var items = [Bundle.main.bundleURL]
            if !status.project.isEmpty { items.append(URL(fileURLWithPath: status.project)) }
            _ = try? await NSWorkspace.shared.recycle(items)
            NSApp.terminate(nil)
        } else {
            status = Status()
            show(L("zapret удалён"))
        }
    }

    func installInTerminal() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", NSHomeDirectory() + "/zapret-macos/zapret.command"]
        try? p.run()
    }
}
