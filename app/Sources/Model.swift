import AppKit
import Foundation
import Observation
import ServiceManagement
import WidgetKit

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    var status = Status()
    var strategies: [Strategy] = []
    var found: [FoundSite] = []
    var ladderLive = LadderLive()
    var youtube = Health.State.unknown
    var discord = Health.State.unknown
    var voice = Health.State.unknown
    var check: CheckRun?
    var diagnostics: [DiagSection] = []
    var diagRunning = false
    var diagError: String?
    var learning = false
    /// the running long commands, for their «Отменить» buttons
    var checkJob: Shell.Job?
    var deepJob: Shell.Job?
    var learnJob: Shell.Job?
    var busy = false
    var toast: String?
    var remoteVersion: String?
    var checkingUpdates = false
    var integrity = Integrity.Result.checking
    /// the DNS for services closed to Russia whose profile is installed: "", "webshift" or "dnsai"
    var dns = ""
    /// chosen, macOS waits for the user to confirm the profile in System Settings
    var dnsPending: String?
    var integrityNotified: String?
    /// the changes of the installed version, shown once after an update
    var whatsNew: String?
    var loginItem = SMAppService.mainApp.status == .enabled

    var installed: Bool { Shell.installed }
    var current: Strategy? { strategies.first { $0.name == status.strategy } }
    var updateAvailable: Bool {
        guard let r = remoteVersion, !status.version.isEmpty else { return false }
        return r.compare(status.version, options: .numeric) == .orderedDescending
    }

    private var lastHealth = Date.distantPast
    private var poller: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    /// changes right after our own actions are not news
    var lastAction = Date.distantPast
    private var youtubeFails = 0
    private var notifiedVersion: String?

    // the state of the parts in the Model*.swift files
    var deep: DeepRun?
    var siteChecking = false
    var siteResult: SiteResult?
    var mySites: [String] = []
    var myExclusions: [String] = []
    var listsChanged = false
    /// site → why it doesn't open (sites-check of the script); empty until checked
    var siteReasons: [String: String] = [:]
    var sitesChecking = false
    var installing = false
    var installError: String?

    init() {
        Task {
            await refresh()
            guard Snapshot.folder == nil else { return }
            await repairAfterSystemUpdate()
            showWhatsNewOnce()
            await checkIntegrity()
        }
        if Snapshot.folder == nil {
            startMonitor()
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await AppModel.shared.afterWake() }
            }
        }
    }

    /// after sleep connections may hang although the network looks the same: if YouTube doesn't open,
    /// the engine finds the network again (repair --net)
    func afterWake() async {
        // the network comes back a few seconds after waking
        try? await Task.sleep(for: .seconds(6))
        await refreshStatus()
        guard installed, status.running, !status.vpn, check?.finished != false else { return }
        if await Health.youtube().isOK { return }
        _ = await Shell.run(["repair", "--net", "--json"], root: true)
        await refreshStatus()
        await checkHealth(force: true)
    }

    /// in the background, while the app runs: notices what happened without the user and tells about it
    private func startMonitor() {
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let before = self.status
                await self.refreshStatus()
                self.notifyChanges(from: before, to: self.status)
                // the widget's container may appear after the app started
                self.updateWidget()
                tick += 1
                // every 10 minutes: does YouTube still open?
                if tick % 30 == 0, self.status.running, !self.status.vpn, self.check?.finished != false {
                    await self.checkHealth(force: true)
                    self.youtubeFails = self.youtube == .fail ? self.youtubeFails + 1 : 0
                    if self.youtubeFails == 2 {
                        let title = self.current?.title ?? ""
                        Notifier.send(L("YouTube не открывается"), L("Стратегия «\(title)» перестала работать."), category: "broken")
                    }
                }
                // every 6 hours: a new version?
                if tick % 1080 == 1 {
                    await self.fetchRemoteVersion()
                    if self.updateAvailable, let v = self.remoteVersion, v != self.notifiedVersion {
                        self.notifiedVersion = v
                        Notifier.send(L("Доступна версия \(v)"), L("Свежие стратегии и исправления."), category: "update")
                    }
                }
            }
        }
    }

    private func notifyChanges(from old: Status, to new: Status) {
        guard !old.version.isEmpty, Date().timeIntervalSince(lastAction) > 15, check?.finished != false else { return }
        // a VPN that takes the whole traffic leaves zapret waiting: not news
        if old.running && !new.running && !new.vpn {
            Notifier.send(L("zapret остановлен"), L("YouTube и Discord снова могут тормозить."), category: "stopped")
        } else if new.running, old.strategy != new.strategy, !old.strategy.isEmpty {
            // autofix picked another one
            let title = Strategy(name: new.strategy).title
            Notifier.send(L("Стратегия сменилась"), L("Автопочинка включила «\(title)»."))
        }
        if old.version != new.version {
            Notifier.send(L("zapret обновлён"), L("Версия \(new.version)."))
        }
        // the background search of smart mode gave sites strategies of their own
        if new.sites > old.sites, !learning {
            Notifier.send(L("Умный режим подобрал стратегии"), L("Сайтов со своей стратегией: \(new.sites)."))
            Task { await refreshFound() }
        }
    }

    /// keeps the status fresh while something is on screen
    func startPolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        await refreshStatus()
        let list = await Shell.run(["list"])
        strategies = list.out.split(separator: "\n").map { Strategy(name: String($0)) }
        await refreshFound()
        await checkHealth(force: true)
        await fetchRemoteVersion()
    }

    /// screenshots for the README: a fixed state, no polling (Snapshot, ZAPRET_DEMO=1)
    var demo = false

    func refreshStatus() async {
        guard installed, !demo else { return }
        let r = await Shell.run(["status", "--json"])
        if let s = try? JSONDecoder().decode(Status.self, from: Data(r.out.utf8)), s != status {
            status = s
            updateWidget()
        }
    }

    /// set by the menu bar icon, the one view that always exists: opens the main window
    var openMainWindow: (() -> Void)?

    /// the widget is sandboxed: the app writes what it shows straight into its container
    func updateWidget() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.zapret-macos.app.widget/Data/Library/Application Support")
        guard FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "running": status.running, "strategy": status.strategy, "engine": status.engine,
            "youtube": youtube == .unknown || youtube == .checking ? NSNull() : youtube.isOK as Any,
            "discord": discord == .unknown || discord == .checking ? NSNull() : discord.isOK as Any,
        ]
        // reload only on changes: WidgetKit gives each widget a limited budget of reloads
        if let data = try? JSONSerialization.data(withJSONObject: info, options: .sortedKeys), data != widgetData {
            try? data.write(to: dir.appendingPathComponent("status.json"))
            widgetData = data
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var widgetData: Data?

    /// the page of the adaptive strategy: what the engine measured and did (nothing from a script without the ladder)
    func refreshLadderLive() async {
        guard !demo else { return }
        let r = await Shell.run(["ladder", "--live", "--json"])
        if let l = try? JSONDecoder().decode(LadderLive.self, from: Data(r.out.utf8)), l != ladderLive { ladderLive = l }
    }

    func refreshFound() async {
        guard !demo else { return }
        let r = await Shell.run(["found", "--json"])
        found = (try? JSONDecoder().decode([FoundSite].self, from: Data(r.out.utf8))) ?? []
    }

    func checkHealth(force: Bool = false) async {
        guard !demo, force || Date().timeIntervalSince(lastHealth) > 30 else { return }
        lastHealth = Date()
        youtube = .checking; discord = .checking; voice = .checking
        async let y = Health.youtube()
        async let d = Health.discord()
        async let v = Health.voice()
        youtube = await y
        discord = await d
        voice = await v
        updateWidget()
    }

    // MARK: actions

    /// a root command; before the passwordless rule exists (first start after an upgrade)
    /// the project's script runs once with the password dialog and installs it
    @discardableResult
    func privileged(_ args: [String], success: String? = nil) async -> Bool {
        lastAction = Date()
        busy = true
        defer { busy = false }
        var r = await Shell.run(args, root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", args)
        }
        await refreshStatus()
        if r.ok {
            if let success { show(success) }
        } else {
            show(r.err.split(separator: "\n").last.map(String.init) ?? L("Не получилось"))
        }
        return r.ok
    }

    func toggle() async {
        if status.running {
            await privileged(["stop"], success: L("zapret остановлен"))
        } else {
            await privileged(["start"], success: L("zapret запущен"))
        }
        await checkHealth(force: true)
    }

    func start(_ s: Strategy) async {
        await privileged(["start", s.name], success: L("Включена \(s.title)"))
        await checkHealth(force: true)
    }

    func setScope(_ v: String) async { await privileged(["scope", v]) }
    func setGame(_ v: String) async { await privileged(["game", v]) }
    func setVideoTCP(_ on: Bool) async { await privileged(["video", on ? "tcp" : "quic"]) }
    func setAutostart(_ on: Bool) async { await privileged(["autostart", on ? "on" : "off"]) }
    func setAutofix(_ on: Bool) async { await privileged(["watchdog", on ? "on" : "off"]) }
    func setAutoupdate(_ on: Bool) async { await privileged(["autoupdate", on ? "on" : "off"]) }
    /// fresh strategies without a release; turned on, the latest pack comes at once
    func setPacks(_ on: Bool) async {
        await privileged(["pack", on ? "on" : "off"])
        if on { await privileged(["pack", "update"]) }
    }

    var telegramBusy = false
    var telegramCheck = Health.State.unknown

    /// the whole path: a handshake like Telegram Desktop's through the proxy, an answer from Telegram
    func testTelegram() async {
        telegramCheck = .checking
        let r = await Shell.run(["telegram", "test"])
        telegramCheck = r.ok ? .ok(nil) : .fail
    }

    func setTelegram(_ on: Bool) async {
        telegramBusy = true
        await privileged(["telegram", on ? "on" : "off"], success: on ? L("Прокси для Telegram включён") : L("Прокси для Telegram выключен"))
        telegramBusy = false
    }

    /// the proxy runs but doesn't reach Telegram: a fresh list of relays, the proxy from scratch
    func restartTelegram() async {
        telegramBusy = true
        await privileged(["telegram", "restart"], success: L("Прокси для Telegram перезапущен"))
        telegramBusy = false
    }

    /// one click from the menu bar: turns the proxy on if needed, then hands the link to Telegram
    func connectTelegramFully() async {
        if !status.telegram || !status.telegramRunning {
            await setTelegram(true)
            for _ in 0..<10 where !status.telegramRunning {
                try? await Task.sleep(for: .milliseconds(500))
                await refreshStatus()
            }
        }
        if status.telegramRunning { connectTelegram() }
    }

    /// Telegram Desktop adds the proxy itself from this link
    func connectTelegram() {
        guard let url = URL(string: status.telegramLink), !status.telegramLink.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    func copyTelegramLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(status.telegramLink, forType: .string)
        show(L("Ссылка скопирована"))
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(L("Не получилось: \(error.localizedDescription)"))
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func learn() async {
        learning = true
        // the other switches wait: learn swaps the engine's settings while it tests
        busy = true
        defer { busy = false }
        lastAction = Date()
        let job = Shell.Job()
        learnJob = job
        var r = await Shell.stream(["learn"], job: job) { _ in }
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["learn"])
        }
        learnJob = nil
        if job.cancelled {
            show(L("Подбор для сайтов отменён"))
        } else if r.ok {
            show(L("Стратегии для сайтов подобраны"))
        } else {
            show(r.err.split(separator: "\n").last.map(String.init) ?? L("Не получилось"))
        }
        await refreshStatus()
        await refreshFound()
        learning = false
    }

    func clearFound() async {
        await privileged(["found", "clear"], success: L("Найденные сайты очищены"))
        await refreshFound()
    }

    private var toastTask: Task<Void, Never>?

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }
}
