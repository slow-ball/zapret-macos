import Foundation

/// Runs zapret.sh: the root-owned copy in /opt/zapret-macos. Commands that change the system go
/// through `sudo -n`, allowed without a password by the rule zapret.sh installs (see install_sudoers).
enum Shell {
    /// ZAPRET_SCRIPT points at another copy, for development
    static let script = ProcessInfo.processInfo.environment["ZAPRET_SCRIPT"] ?? "/opt/zapret-macos/zapret.sh"

    struct Output {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        /// sudo has no rule for us yet: the root copy is older than the app
        var needsPassword: Bool { err.contains("password is required") || err.contains("a terminal is required") }
    }

    static var installed: Bool { FileManager.default.isExecutableFile(atPath: script) }

    /// A long command the user may stop: the search of strategies, the deep search, the search for sites.
    /// SIGTERM goes to sudo, which hands it to the script; its trap puts back the strategy that ran before
    final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        var cancelled: Bool { lock.withLock { stopped } }

        func attach(_ p: Process) {
            lock.withLock {
                process = p
                if stopped { p.terminate() }
            }
        }

        /// a command that has already finished is not cancelled: its result stands
        func cancel() {
            lock.withLock {
                guard let process else {
                    stopped = true
                    return
                }
                if process.isRunning {
                    stopped = true
                    process.terminate()
                }
            }
        }
    }

    static func run(_ args: [String], root: Bool = false) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let p = process(args, root: root)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                return Output(status: -1, out: "", err: error.localizedDescription)
            }
            // read both pipes before waiting: a full pipe would block the script
            async let o = out.fileHandleForReading.readToEnd()
            let e = (try? err.fileHandleForReading.readToEnd()) ?? nil
            let od = (try? await o) ?? nil
            p.waitUntilExit()
            return Output(
                status: p.terminationStatus,
                out: String(decoding: od ?? Data(), as: UTF8.self),
                err: String(decoding: e ?? Data(), as: UTF8.self))
        }.value
    }

    /// Runs as root and hands every output line over as it comes (check --json)
    static func stream(_ args: [String], job: Job? = nil, line: @escaping @Sendable (String) -> Void) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let p = process(args, root: true)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                return Output(status: -1, out: "", err: error.localizedDescription)
            }
            job?.attach(p)
            var buffer = Data()
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    line(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
            }
            let e = (try? err.fileHandleForReading.readToEnd()) ?? nil
            p.waitUntilExit()
            return Output(status: p.terminationStatus, out: "", err: String(decoding: e ?? Data(), as: UTF8.self))
        }.value
    }

    /// Runs a script as root with the macOS password dialog: updates, and the first start
    /// after an upgrade, before the passwordless rule exists
    static func admin(_ script: String, _ args: [String]) async -> Output {
        // snapshots run unattended: no password dialogs
        if Snapshot.folder != nil { return Output(status: 1, out: "", err: "нужен пароль администратора") }
        let command = ([script] + args).map(quote).joined(separator: " ")
        let source = "do shell script \(appleString(command)) with administrator privileges"
        return await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                return Output(status: 1, out: "", err: (error[NSAppleScript.errorMessage] as? String) ?? "")
            }
            return Output(status: 0, out: result?.stringValue ?? "", err: "")
        }.value
    }

    private static func process(_ args: [String], root: Bool) -> Process {
        let p = Process()
        // a development copy (ZAPRET_SCRIPT) runs as is, without sudo
        if root, ProcessInfo.processInfo.environment["ZAPRET_SCRIPT"] == nil {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", script] + args
        } else {
            p.executableURL = URL(fileURLWithPath: script)
            p.arguments = args
        }
        return p
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
