import Foundation
import Network

/// Checks from the app itself, as the user: the same path a browser takes, through pf and the engine
enum Health {
    enum State: Equatable {
        case unknown, checking, ok(String?), fail

        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    /// DPI often lets the first ~16 KB through and then stalls, so the whole page must arrive
    static func youtube() async -> State {
        let start = Date()
        guard let (data, response) = try? await session.data(from: URL(string: "https://www.youtube.com/")!),
            (response as? HTTPURLResponse)?.statusCode == 200, data.count > 300_000
        else { return .fail }
        let speed = Double(data.count) / max(Date().timeIntervalSince(start), 0.05)
        return .ok(speed > 1_000_000 ? L("\(megabytes(speed / 1_000_000)) МБ/с") : L("\(Int(speed / 1000)) КБ/с"))
    }

    static func discord() async -> State {
        guard let (_, response) = try? await session.data(from: URL(string: "https://discord.com/api/v9/gateway")!),
            let code = (response as? HTTPURLResponse)?.statusCode, code < 500
        else { return .fail }
        return .ok(nil)
    }

    /// Discord voice goes over UDP and the strategies look for STUN on ports 19294-19344:
    /// a STUN binding request to such a port shows whether that path works
    static func voice() async -> State {
        await withCheckedContinuation { (cont: CheckedContinuation<State, Never>) in
            let conn = NWConnection(host: "stun.l.google.com", port: 19302, using: .udp)
            let queue = DispatchQueue(label: "stun")
            var finished = false
            func finish(_ s: State) {
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: s)
            }
            var id = [UInt8](repeating: 0, count: 12)
            for i in id.indices { id[i] = UInt8.random(in: 0...255) }
            let request = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + id)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    for _ in 0..<2 { conn.send(content: request, completion: .contentProcessed { _ in }) }
                    conn.receiveMessage { data, _, _, _ in
                        if let data, data.count >= 20, Array(data[8..<20]) == id { finish(.ok(nil)) } else { finish(.fail) }
                    }
                case .failed, .cancelled:
                    finish(.fail)
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(.fail) }
        }
    }
}
