import AppKit
import Foundation

/// Sites: a site that doesn't open, the user's lists and exclusions
extension AppModel {
    /// why each of the user's sites and the found ones doesn't open, all at once
    func checkMySites() async {
        sitesChecking = true
        defer { sitesChecking = false }
        struct Row: Decodable { let site: String; let reason: String }
        var r = await Shell.run(["sites-check", "--json"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["sites-check", "--json"])
        }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(r.out.utf8))) ?? []
        siteReasons = Dictionary(rows.map { ($0.site, $0.reason) }, uniquingKeysWith: { a, _ in a })
        if rows.isEmpty, !r.ok { show(L("Не получилось проверить сайты")) }
    }

    /// a site that doesn't open: into the list, its own strategy if needed, checked like in a browser
    func checkSite(_ address: String) async {
        siteChecking = true
        siteResult = nil
        lastAction = Date()
        var r = await Shell.run(["site", address, "--json"], root: true)
        if r.needsPassword, !status.project.isEmpty {
            r = await Shell.admin(status.project + "/src/zapret.sh", ["site", address, "--json"])
        }
        siteResult =
            (try? JSONDecoder().decode(SiteResult.self, from: Data(r.out.utf8)))
            ?? SiteResult(error: r.err.isEmpty ? L("Проверка не удалась") : r.err)
        siteChecking = false
        loadLists()
        await refreshStatus()
    }

    private func listURL(_ exclusions: Bool) -> URL? {
        status.project.isEmpty
            ? nil
            : URL(fileURLWithPath: status.project + "/lists/" + (exclusions ? "list-exclude-user.txt" : "list-user.txt"))
    }

    func loadLists() {
        func entries(_ url: URL?) -> [String] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        // the screenshots show nobody's own sites
        mySites = demo ? [] : entries(listURL(false))
        myExclusions = demo ? [] : entries(listURL(true))
    }

    /// the files keep their comment lines; zapret reads them on the next start
    private func saveList(_ exclusions: Bool) {
        guard let url = listURL(exclusions) else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let comments = text.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("#") }
        let body = (comments + (exclusions ? myExclusions : mySites)).joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        listsChanged = true
    }

    func addToList(_ raw: String, exclusions: Bool) {
        var d = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        d = String(d.prefix { !"/?#:".contains($0) })
        if d.hasPrefix("www.") { d.removeFirst(4) }
        guard d.contains("."), d.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            show(L("Не похоже на адрес сайта"))
            return
        }
        if exclusions {
            guard !myExclusions.contains(d) else { return }
            myExclusions.append(d)
        } else {
            guard !mySites.contains(d) else { return }
            mySites.append(d)
        }
        saveList(exclusions)
    }

    func removeFromList(_ d: String, exclusions: Bool) {
        if exclusions { myExclusions.removeAll { $0 == d } } else { mySites.removeAll { $0 == d } }
        saveList(exclusions)
    }

    func applyLists() async {
        await privileged(["start"], success: L("Списки применены"))
        listsChanged = false
    }
    func openLists() {
        guard !status.project.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", status.project + "/lists/list-user.txt", status.project + "/lists/list-exclude-user.txt"]
        try? p.run()
    }
}
