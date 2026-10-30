import Foundation
import SwiftUI

/// Do the scripts in /opt/zapret-macos match the signed release of their version? The app checks it
/// itself and runs nothing from that folder: it downloads the archive of the release, checks its
/// signature with the keys built into the app (build/app.sh takes them from src/zapret.sh) and
/// compares every file that comes from it
enum Integrity {
    enum Result: Equatable {
        case checking
        /// the files are the ones of this signed version
        case ok(String)
        /// files that differ from the release or are missing
        case changed(String, [String])
        case unavailable(String)
    }

    /// ZAPRET_INTEGRITY_ROOT: another folder, for development
    static let root = ProcessInfo.processInfo.environment["ZAPRET_INTEGRITY_ROOT"] ?? "/opt/zapret-macos"
    private static let repo = "slow-ball/zapret-macos"

    static func check() async -> Result {
        await Task.detached(priority: .utility) { run() }.value
    }

    /// zapret --check-integrity: the result as text, exit code 0 only if the files are authentic
    static func commandLine() -> Never {
        let r = run()
        print(r)
        if case .ok = r { exit(0) }
        exit(1)
    }

    static func run() -> Result {
        guard
            let version = try? String(contentsOfFile: root + "/VERSION", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty
        else {
            return .unavailable(L("zapret ещё не установлен"))
        }
        guard let keys = Bundle.main.path(forResource: "release-keys", ofType: nil) else {
            return .unavailable(L("в приложении нет ключей подписи"))
        }
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.zapret-macos.app/release/\(version)")
        let archive = cache.appendingPathComponent("zapret-macos-\(version).tar.gz")
        let signature = cache.appendingPathComponent("zapret-macos-\(version).tar.gz.sig")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let base = "https://github.com/\(repo)/releases/download/v\(version)/zapret-macos-\(version).tar.gz"
        for (file, url) in [(archive, base), (signature, base + ".sig")] where !fm.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: URL(string: url)!), !data.isEmpty else {
                return .unavailable(L("не удалось скачать релиз \(version) с GitHub"))
            }
            try? data.write(to: file)
        }
        // a cached archive with a bad signature is not trusted and not kept
        guard
            exec(
                "/usr/bin/ssh-keygen",
                [
                    "-Y", "verify", "-f", keys, "-I", "zapret", "-n", "zapret-release",
                    "-s", signature.path,
                ], stdin: archive)
        else {
            try? fm.removeItem(at: cache)
            return .unavailable(L("подпись релиза \(version) не сошлась"))
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("zapret-integrity-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard exec("/usr/bin/tar", ["-xzf", archive.path, "-C", tmp.path]) else {
            return .unavailable(L("не удалось распаковать релиз \(version)"))
        }
        let src = tmp.appendingPathComponent("zapret-macos/src")
        var changed: [String] = []
        for rel in expected(in: src) {
            let installed = root + "/" + rel
            if !fm.contentsEqual(atPath: src.appendingPathComponent(rel).path, andPath: installed) { changed.append(rel) }
        }
        return changed.isEmpty ? .ok(version) : .changed(version, changed)
    }

    /// what sync_runtime copies from src into /opt/zapret-macos, by the same paths
    private static func expected(in src: URL) -> [String] {
        let fm = FileManager.default
        var out = [
            "zapret.sh", "VERSION", "list-general.txt", "list-google.txt", "list-exclude.txt",
            "ipset-exclude.txt",
        ]
        for dir in ["lib", "lang", "nfqws"] {
            let base = src.appendingPathComponent(dir).path
            for rel in (try? fm.subpathsOfDirectory(atPath: base)) ?? [] {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base + "/" + rel, isDirectory: &isDir), !isDir.boolValue { out.append(dir + "/" + rel) }
            }
        }
        return out.sorted()
    }

    private static func exec(_ tool: String, _ args: [String], stdin: URL? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let stdin { p.standardInput = try? FileHandle(forReadingFrom: stdin) }
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// On the Checkup page: whether the installed files are the signed release
struct IntegrityCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, gradient: LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .top, endPoint: .bottom), size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .changed(_, let files) = model.integrity {
                    Text(files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " …" : ""))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if case .changed(let v, _) = model.integrity {
                Button("Переустановить \(v)") { Task { await model.reinstall() } }
                    .buttonStyle(PillButtonStyle(tint: Theme.warn))
                    .disabled(model.busy)
            } else if model.integrity != .checking {
                Button("Проверить") { Task { await model.checkIntegrity() } }
                    .buttonStyle(PillButtonStyle(tint: .gray))
            }
        }
        .padding(16)
        .glassCard()
        .animation(Theme.spring, value: model.integrity)
    }

    private var symbol: String {
        switch model.integrity {
        case .ok: "checkmark.shield.fill"
        case .changed: "exclamationmark.shield.fill"
        case .checking: "shield"
        case .unavailable: "shield.slash"
        }
    }

    private var tint: Color {
        switch model.integrity {
        case .ok: Theme.ok
        case .changed: Theme.warn
        default: .gray
        }
    }

    private var title: LocalizedStringKey {
        switch model.integrity {
        case .ok: "Файлы zapret подлинные"
        case .changed: "Файлы zapret изменены"
        case .checking: "Проверяю файлы zapret…"
        case .unavailable: "Подлинность не проверена"
        }
    }

    private var text: LocalizedStringKey {
        switch model.integrity {
        case .ok(let v): "Совпадают с подписанным релизом \(v)."
        case .changed(let v, let files): "Не совпадают с подписанным релизом \(v): \(files.count). Переустановка вернёт файлы релиза."
        case .checking: "Сверяю с подписанным релизом на GitHub."
        case .unavailable(let why): "\(why)"
        }
    }
}
