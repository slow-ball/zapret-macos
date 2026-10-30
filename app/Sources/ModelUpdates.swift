import AppKit
import Foundation

/// Updates: the latest release, installing it and going back, What's New, the integrity check, repair after a macOS update
extension AppModel {
    /// the latest release: …/releases/latest redirects to …/releases/tag/vX.Y.Z. only released
    /// versions are offered, not every change on GitHub
    @discardableResult
    func fetchRemoteVersion() async -> Bool {
        // the screenshots show their own state, not GitHub's
        guard !demo else { return true }
        let url = URL(string: "https://github.com/slow-ball/zapret-macos/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let tag = response.url?.lastPathComponent, tag.hasPrefix("v")
        else { return false }
        let v = String(tag.dropFirst())
        guard v.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        // the demo may have begun while GitHub answered
        guard !demo else { return true }
        remoteVersion = v
        return true
    }

    /// the button: asks GitHub right now and says what it found
    func checkForUpdates() async {
        checkingUpdates = true
        let ok = await fetchRemoteVersion()
        checkingUpdates = false
        if !ok {
            show(L("GitHub не ответил — попробовать позже"))
        } else if updateAvailable, let v = remoteVersion {
            show(L("Доступна версия \(v)"))
        } else {
            show(L("Установлена последняя версия"))
        }
    }

    /// after an update: the changes of the new version, once. Not on the first launch
    func showWhatsNewOnce() {
        let seen = UserDefaults.standard.string(forKey: "seenVersion")
        guard !status.version.isEmpty, seen != status.version else { return }
        UserDefaults.standard.set(status.version, forKey: "seenVersion")
        if seen != nil { showWhatsNew() }
    }

    func showWhatsNew() {
        whatsNew = Changelog.section(for: status.version, project: status.project)
        if whatsNew == nil { show(L("Список изменений не найден")) }
    }

    /// a macOS update may reset the sudoers rule, the services and the firewall rules: on the first
    /// launch on a new build of the system zapret checks and puts them back
    func repairAfterSystemUpdate() async {
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        let seen = UserDefaults.standard.string(forKey: "osBuild")
        UserDefaults.standard.set(build, forKey: "osBuild")
        guard installed, let seen, seen != build else { return }
        var r = await Shell.run(["repair", "--json"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["repair", "--json"])
        }
        struct Repair: Decodable { let fixed: [String] }
        let fixed = (try? JSONDecoder().decode(Repair.self, from: Data(r.out.utf8)))?.fixed ?? []
        if !fixed.isEmpty {
            let list = fixed.joined(separator: ", ")
            Notifier.send(L("macOS обновилась"), L("zapret всё проверил и восстановил: \(list)."))
        }
        await refreshStatus()
    }
    /// updates run without a password: the script installs only signed releases. a missing sudo rule falls
    /// back to the password dialog
    private func updateRun(_ args: [String]) async -> Shell.Output {
        lastAction = Date()
        busy = true
        defer { busy = false }
        var r = await Shell.run(args, root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", args)
        }
        return r
    }

    func update() async {
        let r = await updateRun(["update"])
        show(r.ok ? L("Обновлено") : L("Не получилось обновить"))
        await refresh()
        if r.ok { showWhatsNewOnce() }
        await checkIntegrity()
    }

    func rollback() async {
        guard !status.previous.isEmpty else { return }
        let to = status.previous
        let r = await updateRun(["update", "--to", to])
        show(r.ok ? L("Возвращена версия \(to)") : L("Не получилось вернуть версию"))
        if r.ok { UserDefaults.standard.set(to, forKey: "seenVersion") }
        await refresh()
        await checkIntegrity()
    }
    /// the files of /opt/zapret-macos against the signed release of their version (Integrity)
    func checkIntegrity() async {
        guard installed, !demo else { return }
        integrity = .checking
        integrity = await Integrity.check()
        if case .changed(let v, _) = integrity, integrityNotified != v {
            integrityNotified = v
            Notifier.send(L("Файлы zapret изменены"), L("Они не совпадают с подписанным релизом \(v). Переустановить — в разделе «Проверка»."))
        }
    }

    /// the same signed version again: the files of the release come back
    func reinstall() async {
        let v = status.version
        let r = await updateRun(["update", "--to", v])
        show(r.ok ? L("Версия \(v) переустановлена") : L("Не получилось переустановить"))
        await refresh()
        await checkIntegrity()
    }
}
