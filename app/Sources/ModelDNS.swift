import AppKit

/// The DNS for neural networks
extension AppModel {
    func refreshDNS() async {
        guard installed, !demo else { return }
        struct S: Decodable { let dns: String }
        let r = await Shell.run(["dns", "status", "--json"], root: true)
        if let s = try? JSONDecoder().decode(S.self, from: Data(r.out.utf8)) { dns = s.dns }
    }

    /// another DNS: zapret prepares its profile and opens System Settings, where the user installs it;
    /// meanwhile the app waits for it (up to three minutes)
    func setDNS(_ id: String) async {
        guard id != dns else { return }
        if id.isEmpty {
            dnsPending = nil
            await privileged(["dns", "off"], success: L("DNS: системный"))
            await refreshDNS()
            return
        }
        dnsPending = id
        guard await privileged(["dns", id]) else { dnsPending = nil; return }
        for _ in 0..<60 where dnsPending == id {
            await refreshDNS()
            if dns == id {
                dnsPending = nil
                show(L("DNS включён"))
                await checkHealth(force: true)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        if dnsPending == id { dnsPending = nil }
    }

    func openProfiles() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Profiles-Settings.extension")!)
    }
}
