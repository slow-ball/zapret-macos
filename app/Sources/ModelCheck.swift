import AppKit
import Foundation

/// Strategy search: the check of all strategies and the deep search for one site
extension AppModel {
    /// the likely strategies first, up to a good one; all: every strategy, the fastest wins
    func runCheck(all: Bool = false) async {
        guard check?.finished != false else { return }
        check = CheckRun()
        // the passwordless rule must exist: check streams its output, the password dialog can't
        let probe = await Shell.run(["found"], root: true)
        if probe.needsPassword, !status.project.isEmpty {
            _ = await Shell.admin(status.project + "/src/zapret.sh", ["start"])
        }
        let job = Shell.Job()
        checkJob = job
        let r = await Shell.stream(["check", "--json"] + (all ? ["--all"] : []), job: job) { [weak self] line in
            Task { @MainActor in self?.handle(line) }
        }
        checkJob = nil
        if job.cancelled {
            check?.cancelled = true
        } else if !r.ok, check?.error == nil, check?.best == nil {
            check?.error = r.needsPassword ? L("Нет прав: перезапустить стратегию") : L("Подбор прервался")
        }
        check?.finished = true
        lastAction = Date()
        await refreshStatus()
        await checkHealth(force: true)
        // started from a notification or the hot key: the result is news too
        if !NSApp.isActive, !job.cancelled {
            if let best = check?.best {
                Notifier.send(L("Стратегия подобрана"), L("Включена «\(Strategy(name: best).title)»."))
            } else {
                Notifier.send(L("Подбор не помог"), check?.error ?? L("Ни одна стратегия не прошла проверки."))
            }
        }
    }

    /// the deep search for one site: hundreds of options, the first working one becomes the site's strategy
    func runDeep(_ site: String) async {
        guard deep?.finished != false else { return }
        deep = DeepRun(site: site)
        lastAction = Date()
        let probe = await Shell.run(["found"], root: true)
        if probe.needsPassword, !status.project.isEmpty {
            _ = await Shell.admin(status.project + "/src/zapret.sh", ["start"])
        }
        let job = Shell.Job()
        deepJob = job
        let r = await Shell.stream(["deep", site, "--json"], job: job) { [weak self] line in
            Task { @MainActor in self?.handleDeep(line) }
        }
        deepJob = nil
        if job.cancelled {
            deep?.cancelled = true
        } else if !r.ok, deep?.error == nil, deep?.finished != true {
            deep?.error = L("Подбор прервался")
        }
        deep?.finished = true
        lastAction = Date()
        let list = await Shell.run(["list"])
        strategies = list.out.split(separator: "\n").map { Strategy(name: String($0)) }
        await refreshStatus()
        await checkHealth(force: true)
    }

    /// the trap of the script needs a few seconds to put the strategy back: the card says so meanwhile
    func cancelDeep() {
        deepJob?.cancel()
        deep?.option = L("Отменяю, возвращаю прежнюю стратегию…")
    }

    private func handleDeep(_ line: String) {
        if deepJob?.cancelled == true { return }
        if let e = scriptEvent(line) { deep?.apply(e) }
    }

    private func handle(_ line: String) {
        if let e = scriptEvent(line) { check?.apply(e) }
    }
}
