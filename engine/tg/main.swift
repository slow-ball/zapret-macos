// zapret-tg: the Telegram proxy of zapret-macos, without Python.
//
// Telegram Desktop connects to it as to an MTProto proxy (obfuscated2, a "dd" secret). It reads the client's
// 64-byte handshake, learns the data center, and carries the traffic to Telegram re-encrypted: over WebSocket to
// the web servers of Telegram (kwsN.web.telegram.org/apiws, reached at 149.154.167.220 with the name inside TLS:
// a DNS that lies about the name changes nothing) for DC 2 and 4; where those don't answer, and for the other
// data centers, over the community's WebSocket relays on Cloudflare; straight to the data center last. The
// protocol is the one of Flowseal's tg-ws-proxy (MIT), written anew.
//
//   zapret-tg serve <port> <secret: 32 hex>         the proxy on 127.0.0.1
//   zapret-tg check <host> <port> <secret> [dc]     a handshake like Telegram Desktop's and the first request of
//                                                   authorization through the proxy: OK if Telegram answered
//   zapret-tg stun                                  a STUN request like Discord voice's: OK if it is answered

import CommonCrypto
import Foundation
import Network

/// four bytes at `i`, little-endian (spelled out: older compilers give up on the one-line expression)
func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    var v = UInt32(b[i])
    v |= UInt32(b[i + 1]) << 8
    v |= UInt32(b[i + 2]) << 16
    v |= UInt32(b[i + 3]) << 24
    return v
}

// MARK: - crypto

/// AES-256-CTR with a big-endian counter, as MTProto's obfuscation wants it; one stream, updated piece by piece.
/// Sendable by hand: every stream is used on the one serial queue of the proxy
final class AESCTR: @unchecked Sendable {
    private var ref: CCCryptorRef?

    init(key: [UInt8], iv: [UInt8]) {
        CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            iv, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
    }

    deinit { if let ref { CCCryptorRelease(ref) } }

    func update(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        CCCryptorUpdate(ref, data, data.count, &out, out.count, &moved)
        return out
    }
}

func sha256(_ data: [UInt8]) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256(data, CC_LONG(data.count), &h)
    return h
}

func randomBytes(_ n: Int) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: n)
    _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
    return b
}

func hexBytes(_ s: String) -> [UInt8]? {
    let c = Array(s.utf8)
    guard c.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    for i in stride(from: 0, to: c.count, by: 2) {
        guard let b = UInt8(String(decoding: c[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

// MARK: - the handshake

let tagAbridged: [UInt8] = [0xef, 0xef, 0xef, 0xef]
let tagIntermediate: [UInt8] = [0xee, 0xee, 0xee, 0xee]
let tagPadded: [UInt8] = [0xdd, 0xdd, 0xdd, 0xdd]

/// a random 64-byte handshake nothing could mistake for another protocol
func freshInit() -> [UInt8] {
    while true {
        let r = randomBytes(64)
        let start = Array(r[0..<4])
        if r[0] == 0xef || [Array("HEAD".utf8), Array("POST".utf8), Array("GET ".utf8), Array("OPTI".utf8), tagIntermediate, tagPadded,
            [0x16, 0x03, 0x01, 0x02]].contains(start) || r[4..<8].allSatisfy({ $0 == 0 }) {
            continue
        }
        return r
    }
}

/// the four ciphers of a session: from the client, to the client, to Telegram, from Telegram
struct Ciphers {
    let fromClient, toClient, toTelegram, fromTelegram: AESCTR
}

struct ClientHello {
    let dc: Int
    let media: Bool
    let tag: [UInt8]
    let keyIV: [UInt8]  // bytes 8..<56 of the client's handshake
}

/// the client's handshake, decrypted with the key of the secret; nil — not ours (another secret, another protocol)
func readHello(_ h: [UInt8], secret: [UInt8]) -> ClientHello? {
    guard h.count == 64 else { return nil }
    let keyIV = Array(h[8..<56])
    let plain = AESCTR(key: sha256(Array(keyIV[0..<32]) + secret), iv: Array(keyIV[32..<48])).update(h)
    let tag = Array(plain[56..<60])
    guard tag == tagAbridged || tag == tagIntermediate || tag == tagPadded else { return nil }
    let idx = Int(Int16(bitPattern: UInt16(plain[60]) | UInt16(plain[61]) << 8))
    return ClientHello(dc: abs(idx), media: idx < 0, tag: tag, keyIV: keyIV)
}

/// our own handshake toward Telegram for that data center and protocol, and the ciphers of the session
func session(for hello: ClientHello, secret: [UInt8]) -> (relayInit: [UInt8], ciphers: Ciphers) {
    var relay = freshInit()
    let enc = AESCTR(key: Array(relay[8..<40]), iv: Array(relay[40..<56]))
    let full = enc.update(relay)
    var tail = hello.tag
    let idx = UInt16(bitPattern: Int16(hello.media ? -hello.dc : hello.dc))
    tail += [UInt8(idx & 0xff), UInt8(idx >> 8)] + randomBytes(2)
    for i in 0..<8 { relay[56 + i] = tail[i] ^ (full[56 + i] ^ relay[56 + i]) }
    // the stream to Telegram goes on after the handshake: `enc` is already past its 64 bytes
    let relayRev = Array(relay[8..<56].reversed())
    let fromTelegram = AESCTR(key: Array(relayRev[0..<32]), iv: Array(relayRev[32..<48]))

    let fromClient = AESCTR(key: sha256(Array(hello.keyIV[0..<32]) + secret), iv: Array(hello.keyIV[32..<48]))
    _ = fromClient.update([UInt8](repeating: 0, count: 64))
    let rev = Array(hello.keyIV.reversed())
    let toClient = AESCTR(key: sha256(Array(rev[0..<32]) + secret), iv: Array(rev[32..<48]))
    return (relay, Ciphers(fromClient: fromClient, toClient: toClient, toTelegram: enc, fromTelegram: fromTelegram))
}

// MARK: - MTProto packets in the stream

/// cuts the client's stream into MTProto transport packets: each goes to the WebSocket as a frame of its own
final class Splitter {
    private let tag: [UInt8]
    private var cipher: [UInt8] = []
    private var plain: [UInt8] = []
    private var broken = false

    init(tag: [UInt8]) { self.tag = tag }

    func split(cipher c: [UInt8], plain p: [UInt8]) -> [[UInt8]] {
        if broken { return [c] }
        cipher += c
        plain += p
        var parts: [[UInt8]] = []
        while let n = nextLength() {
            if n <= 0 {
                // not a packet we know: from now on as it comes
                broken = true
                parts.append(cipher)
                cipher = []
                plain = []
                break
            }
            parts.append(Array(cipher[0..<n]))
            cipher.removeFirst(n)
            plain.removeFirst(n)
        }
        return parts
    }

    private func nextLength() -> Int? {
        guard !plain.isEmpty else { return nil }
        if tag == tagAbridged {
            let first = plain[0]
            var len = 0
            var header = 1
            if first == 0x7f || first == 0xff {
                guard plain.count >= 4 else { return nil }
                len = Int(le32(plain, 0) >> 8) * 4
                header = 4
            } else {
                len = Int(first & 0x7f) * 4
            }
            if len <= 0 { return 0 }
            return plain.count >= header + len ? header + len : nil
        }
        guard plain.count >= 4 else { return nil }
        let len = Int(le32(plain, 0) & 0x7fff_ffff)
        if len <= 0 { return 0 }
        return plain.count >= 4 + len ? 4 + len : nil
    }
}

// MARK: - connections

let queue = DispatchQueue(label: "zapret-tg")

func log(_ s: String) {
    FileHandle.standardError.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + s + "\n").utf8))
}

/// what Telegram is reached by: a WebSocket to its web servers, or the data center itself
protocol Upstream: AnyObject {
    func send(_ data: [UInt8])
    func receive(_ handler: @escaping ([UInt8]?) -> Void)
    func close()
}

/// a TCP connection straight to a data center
final class TCPUpstream: Upstream {
    let conn: NWConnection

    init(conn: NWConnection) { self.conn = conn }

    func send(_ data: [UInt8]) { conn.send(content: Data(data), completion: .idempotent) }

    func receive(_ handler: @escaping ([UInt8]?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty { handler(Array(data)) }
            if done || error != nil { handler(nil) } else { self.receive(handler) }
        }
    }

    func close() { conn.cancel() }
}

/// a WebSocket over TLS, written by hand: the name of the web server goes inside TLS and into Host while the
/// connection goes to a fixed address. our frames are masked, Telegram's are not
final class WSUpstream: Upstream {
    let conn: NWConnection
    /// what came but isn't a whole frame yet; the upgrade leaves here whatever followed its headers
    var buffer: [UInt8] = []

    init(conn: NWConnection) { self.conn = conn }

    func send(_ data: [UInt8]) {
        var frame: [UInt8] = [0x82]
        if data.count < 126 {
            frame.append(UInt8(data.count) | 0x80)
        } else if data.count < 65536 {
            let hi = UInt8(data.count >> 8), lo = UInt8(data.count & 0xff)
            frame += [UInt8(126 | 0x80), hi, lo]
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() { frame.append(UInt8((UInt64(data.count) >> (UInt64(i) * 8)) & 0xff)) }
        }
        let mask = randomBytes(4)
        frame += mask
        frame += data.enumerated().map { $0.element ^ mask[$0.offset & 3] }
        conn.send(content: Data(frame), completion: .idempotent)
    }

    func receive(_ handler: @escaping ([UInt8]?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty {
                self.buffer += Array(data)
                while let payload = self.nextFrame() {
                    if let payload { handler(payload) } else { handler(nil); return }
                }
            }
            if done || error != nil { handler(nil) } else { self.receive(handler) }
        }
    }

    /// the next whole frame: its payload ([] for control frames handled here), nil inside when it closes,
    /// nil outside when not all of it has come yet
    private func nextFrame() -> [UInt8]?? {
        guard buffer.count >= 2 else { return nil }
        let op = buffer[0] & 0x0f
        let masked = buffer[1] & 0x80 != 0
        var len = Int(buffer[1] & 0x7f)
        var at = 2
        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = Int(buffer[2]) << 8 | Int(buffer[3])
            at = 4
        } else if len == 127 {
            guard buffer.count >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = len << 8 | Int(buffer[i]) }
            at = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.count >= at + 4 else { return nil }
            mask = Array(buffer[at..<at + 4])
            at += 4
        }
        guard buffer.count >= at + len else { return nil }
        var payload = Array(buffer[at..<at + len])
        if masked { payload = payload.enumerated().map { $0.element ^ mask[$0.offset & 3] } }
        buffer.removeFirst(at + len)
        switch op {
        case 0x8: return .some(nil)  // close
        case 0x9:  // ping: pong with the same payload
            var pong: [UInt8] = [0x8a, UInt8(payload.count) | 0x80]
            let m = randomBytes(4)
            pong += m + payload.enumerated().map { $0.element ^ m[$0.offset & 3] }
            conn.send(content: Data(pong), completion: .idempotent)
            return .some([])
        case 0xa: return .some([])
        default: return .some(payload)
        }
    }

    func close() { conn.cancel() }
}

let wsAddress = "149.154.167.220"

/// relays of the community of tg-ws-proxy on Cloudflare: where a provider blocks the addresses of Telegram,
/// kwsN.<relay>/apiws still gets there. the list as tg-ws-proxy keeps it (letters shifted), the script adds a
/// fresher one in cf-domains.txt next to the binary
let relaysEncoded = [
    "virkgj.com", "vmmzovy.com", "mkuosckvso.com", "zaewayzmplad.com", "twdmbzcm.com", "awzwsldi.com", "clngqrflngqin.com",
    "tjacxbqtj.com", "bxaxtxmrw.com", "dmohrsgmohcrwb.com", "vwbmtmoi.com", "khgrre.com", "ulihssf.com", "tmhqsdqmfpmk.com",
    "xwuwoqbm.com", "orgcnunpj.com", "zhkuldz.com", "zypoljnslxa.com", "efabnxaowuzs.com", "zaftuzsftqdq.com",
]

func decodeRelay(_ s: String) -> String {
    guard s.hasSuffix(".com") else { return s }
    let p = s.dropLast(4)
    let n = p.filter { $0.isLetter }.count
    let shifted = p.map { c -> Character in
        guard let a = c.asciiValue, c.isLetter else { return c }
        let base: UInt8 = a >= 97 ? 97 : 65
        return Character(UnicodeScalar(UInt8((Int(a - base) - n % 26 + 26) % 26) + base))
    }
    return String(shifted) + ".co.uk"
}

var relays: [String] = {
    var list = relaysEncoded
    let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("cf-domains.txt")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        let fresh = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if fresh.count >= 3 { list = fresh }
    }
    return list.map(decodeRelay)
}()

/// the relay that answered last: tried first
var goodRelay: [Int: String] = [:]
/// relays that didn't answer lately: tried after the others for five minutes
var relayDown: [String: Date] = [:]
/// direct ways to Telegram didn't answer: for ten minutes the relays go first, no waiting on what is blocked
var directDown: Date?
let dcAddresses: [Int: String] = [1: "149.154.175.50", 2: "149.154.167.51", 3: "149.154.175.100", 4: "149.154.167.91", 5: "149.154.171.5", 203: "91.105.192.100"]

/// opens a TCP connection, TLS with the name `sni` if given; the handler gets it ready, or nil after `wait` seconds
func connect(_ host: String, _ port: UInt16, sni: String?, wait: Double = 8, _ done: @escaping (NWConnection?) -> Void) {
    let params: NWParameters
    if let sni {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        params = NWParameters(tls: tls)
    } else {
        params = .tcp
    }
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    var finished = false
    let finish: (NWConnection?) -> Void = { c in
        guard !finished else { return }
        finished = true
        if c == nil { conn.cancel() }
        done(c)
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready: finish(conn)
        case .failed, .cancelled: finish(nil)
        case .waiting: finish(nil)
        default: break
        }
    }
    conn.start(queue: queue)
    queue.asyncAfter(deadline: .now() + wait) { finish(nil) }
}

/// the upgrade to WebSocket at `domain`/apiws, at `address` (or where the name points): the handler gets the
/// WebSocket, or nil
func openWebSocket(_ domain: String, at address: String? = nil, wait: Double = 8, _ done: @escaping (WSUpstream?) -> Void) {
    connect(address ?? domain, 443, sni: domain, wait: wait) { conn in
        guard let conn else { return done(nil) }
        let key = Data(randomBytes(16)).base64EncodedString()
        let req = "GET /apiws HTTP/1.1\r\nHost: \(domain)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
        conn.send(content: Data(req.utf8), completion: .idempotent)
        var head: [UInt8] = []
        func readHead() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isDone, error in
                if let data { head += Array(data) }
                if let end = head.firstRange(of: Array("\r\n\r\n".utf8)) {
                    let status = String(decoding: head[..<end.lowerBound], as: UTF8.self)
                    guard status.hasPrefix("HTTP/1.1 101") else {
                        conn.cancel()
                        return done(nil)
                    }
                    let ws = WSUpstream(conn: conn)
                    // whatever came after the headers is the beginning of the frames
                    ws.buffer = Array(head[end.upperBound...])
                    return done(ws)
                }
                if isDone || error != nil || head.count > 16384 {
                    conn.cancel()
                    return done(nil)
                }
                readHead()
            }
        }
        readHead()
    }
}

// MARK: - a client of the proxy

/// one Telegram Desktop connection: its handshake, the way to Telegram, the two streams re-encrypted
final class Session {
    let client: NWConnection
    let secret: [UInt8]
    var upstream: Upstream?
    var closed = false

    init(client: NWConnection, secret: [UInt8]) {
        self.client = client
        self.secret = secret
    }

    func start() {
        client.start(queue: queue)
        readExactly(64) { [self] h in
            guard let h, let hello = readHello(h, secret: secret) else {
                log("bad handshake: another secret or protocol")
                return close()
            }
            let (relayInit, ciphers) = session(for: hello, secret: secret)
            reach(hello) { [self] up, ws in
                guard let up else {
                    log("DC\(hello.dc)\(hello.media ? " media" : ""): Telegram unreachable")
                    return close()
                }
                upstream = up
                up.send(relayInit)
                let splitter = ws ? Splitter(tag: hello.tag) : nil
                pumpUp(ciphers, splitter)
                up.receive { [self] data in
                    guard let data else { return close() }
                    if data.isEmpty { return }
                    send(ciphers.toClient.update(ciphers.fromTelegram.update(data)))
                }
            }
        }
    }

    /// DC 2 and 4 over WebSocket to Telegram's own web servers (media: the -1 server first), then the relays on
    /// Cloudflare, then straight to the data center
    func reach(_ hello: ClientHello, _ done: @escaping (Upstream?, Bool) -> Void) {
        var direct: [String] = []
        if (hello.dc == 2 || hello.dc == 4) && (directDown.map { Date().timeIntervalSince($0) > 600 } ?? true) {
            if hello.media { direct.append("kws\(hello.dc)-1.web.telegram.org") }
            direct.append("kws\(hello.dc).web.telegram.org")
        }
        let now = Date()
        var viaRelay =
            relays.filter { relayDown[$0].map { now.timeIntervalSince($0) > 300 } ?? true }
            + relays.filter { relayDown[$0].map { now.timeIntervalSince($0) <= 300 } ?? false }
        if let good = goodRelay[hello.dc], let i = viaRelay.firstIndex(of: good) { viaRelay.insert(viaRelay.remove(at: i), at: 0) }
        var triedRelays = 0
        func next() {
            if !direct.isEmpty {
                let d = direct.removeFirst()
                // where these addresses are blocked they don't answer at all: four seconds are enough
                return openWebSocket(d, at: wsAddress, wait: 4) { ws in
                    if let ws { return done(ws, true) }
                    if direct.isEmpty { directDown = Date() }
                    next()
                }
            }
            // three relays at most for one connection: each try may wait
            if !viaRelay.isEmpty && triedRelays < 3 {
                let r = viaRelay.removeFirst()
                triedRelays += 1
                // a relay that works answers within a second or two
                return openWebSocket("kws\(hello.dc).\(r)", wait: 4) { ws in
                    if let ws {
                        goodRelay[hello.dc] = r
                        relayDown[r] = nil
                        return done(ws, true)
                    }
                    relayDown[r] = Date()
                    if goodRelay[hello.dc] == r { goodRelay[hello.dc] = nil }
                    next()
                }
            }
            guard let ip = dcAddresses[hello.dc] else { return done(nil, false) }
            connect(ip, 443, sni: nil) { c in done(c.map { TCPUpstream(conn: $0) }, false) }
        }
        next()
    }

    func pumpUp(_ ciphers: Ciphers, _ splitter: Splitter?) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data, !data.isEmpty, let up = upstream {
                let plain = ciphers.fromClient.update(Array(data))
                let out = ciphers.toTelegram.update(plain)
                if let splitter {
                    for part in splitter.split(cipher: out, plain: plain) { up.send(part) }
                } else {
                    up.send(out)
                }
            }
            if done || error != nil { return close() }
            pumpUp(ciphers, splitter)
        }
    }

    func send(_ bytes: [UInt8]) { client.send(content: Data(bytes), completion: .idempotent) }

    func readExactly(_ n: Int, _ done: @escaping ([UInt8]?) -> Void) {
        var got: [UInt8] = []
        func more() {
            client.receive(minimumIncompleteLength: 1, maximumLength: n - got.count) { data, _, isDone, error in
                if let data { got += Array(data) }
                if got.count == n { return done(got) }
                if isDone || error != nil { return done(nil) }
                more()
            }
        }
        more()
    }

    func close() {
        guard !closed else { return }
        closed = true
        upstream?.close()
        client.cancel()
        sessions.removeValue(forKey: ObjectIdentifier(self))
    }
}

var sessions: [ObjectIdentifier: Session] = [:]

func serve(port: UInt16, secret: [UInt8]) -> Never {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    params.allowLocalEndpointReuse = true
    guard let listener = try? NWListener(using: params) else {
        log("can't listen on 127.0.0.1:\(port)")
        exit(1)
    }
    listener.newConnectionHandler = { conn in
        let s = Session(client: conn, secret: secret)
        sessions[ObjectIdentifier(s)] = s
        s.start()
    }
    listener.stateUpdateHandler = { state in
        if case .failed(let e) = state {
            log("listener failed: \(e)")
            exit(1)
        }
        if case .ready = state { log("listening on 127.0.0.1:\(port)") }
    }
    listener.start(queue: queue)
    dispatchMain()
}

// MARK: - the check

/// the way Telegram Desktop talks to the proxy, and req_pq_multi without encryption: Telegram answers resPQ
func check(host: String, port: UInt16, secret: [UInt8], dc: Int) -> Never {
    var initBytes = freshInit()
    initBytes[56..<60] = tagPadded[...]
    let idx = UInt16(bitPattern: Int16(dc))
    initBytes[60] = UInt8(idx & 0xff)
    initBytes[61] = UInt8(idx >> 8)
    let rev = Array(initBytes[8..<56].reversed())
    let enc = AESCTR(key: sha256(Array(initBytes[8..<40]) + secret), iv: Array(initBytes[40..<56]))
    let dec = AESCTR(key: sha256(Array(rev[0..<32]) + secret), iv: Array(rev[32..<48]))
    let encrypted = enc.update(initBytes)
    initBytes[56..<64] = encrypted[56..<64]

    let nonce = randomBytes(16)
    var body: [UInt8] = [0xf1, 0x8e, 0x7e, 0xbe] + nonce  // req_pq_multi
    var msg = [UInt8](repeating: 0, count: 8)  // auth_key_id 0
    let msgID = UInt64(Date().timeIntervalSince1970) << 32
    for i in 0..<8 { msg.append(UInt8((msgID >> (UInt64(i) * 8)) & 0xff)) }
    for i in 0..<4 { msg.append(UInt8((body.count >> (i * 8)) & 0xff)) }
    msg += body
    body = []
    var payload: [UInt8] = []
    for i in 0..<4 { payload.append(UInt8((msg.count >> (i * 8)) & 0xff)) }
    payload += msg
    let first = initBytes + enc.update(payload)

    let t0 = Date()
    var buf: [UInt8] = []
    func finish(_ ok: Bool, _ text: String) -> Never {
        print(text)
        exit(ok ? 0 : 1)
    }
    func attempt(_ n: Int) {
        connect(host, port, sni: nil) { conn in
            guard let conn else {
                if n >= 9 { finish(false, "FAIL: прокси не принимает соединения") }
                queue.asyncAfter(deadline: .now() + 0.5) { attempt(n + 1) }
                return
            }
            conn.send(content: Data(first), completion: .idempotent)
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                    if let data { buf += dec.update(Array(data)) }
                    if buf.count >= 4 {
                        let len = Int(le32(buf, 0) & 0x7fff_ffff)
                        if buf.count >= 4 + len, len >= 40 {
                            let m = Array(buf[4..<4 + len])
                            let ctor = le32(m, 20)
                            let dt = String(format: "%.2f", Date().timeIntervalSince(t0))
                            if ctor == 0x0516_2463 && Array(m[24..<40]) == nonce { finish(true, "OK resPQ from DC\(dc) in \(dt)s") }
                            finish(false, "unexpected reply ctor=\(String(ctor, radix: 16)) len=\(len)")
                        }
                    }
                    if done || error != nil {
                        finish(false, "FAIL: no reply in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s (got \(buf.count) bytes)")
                    }
                    read()
                }
            }
            read()
        }
    }
    attempt(0)
    queue.asyncAfter(deadline: .now() + 15) {
        finish(false, "FAIL: no reply in 15s (got \(buf.count) bytes)")
    }
    dispatchMain()
}

// MARK: - STUN

/// a STUN binding request to stun.l.google.com:19302, the way Discord voice starts: OK if it answers. zapret
/// checks the path of voice with it, through its engine or past it
func stun() -> Never {
    let conn = NWConnection(host: "stun.l.google.com", port: 19302, using: .udp)
    let tid = randomBytes(12)
    let req: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42] + tid
    var tries = 0
    func send() {
        tries += 1
        conn.send(content: Data(req), completion: .idempotent)
        conn.receive(minimumIncompleteLength: 20, maximumLength: 2048) { data, _, _, _ in
            if let d = data.map(Array.init), d.count >= 20, Array(d[8..<20]) == tid {
                print("OK")
                exit(0)
            }
        }
        queue.asyncAfter(deadline: .now() + 2) {
            if tries < 2 { send() } else { exit(1) }
        }
    }
    conn.stateUpdateHandler = { state in
        if case .ready = state { send() }
        if case .failed = state { exit(1) }
    }
    conn.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 6) { exit(1) }
    dispatchMain()
}

// MARK: - main

let args = CommandLine.arguments
switch (args.count > 1 ? args[1] : "", args.count) {
case ("serve", 4):
    guard let port = UInt16(args[2]), let secret = hexBytes(args[3]), secret.count == 16 else {
        print("zapret-tg serve <port> <secret: 32 hex>")
        exit(2)
    }
    serve(port: port, secret: secret)
case ("stun", 2):
    stun()
case ("check", 5), ("check", 6):
    guard let port = UInt16(args[3]), let secret = hexBytes(args[4]), secret.count == 16 else {
        print("zapret-tg check <host> <port> <secret> [dc]")
        exit(2)
    }
    check(host: args[2], port: port, secret: secret, dc: args.count == 6 ? Int(args[5]) ?? 2 : 2)
default:
    print("zapret-tg serve <port> <secret: 32 hex>\nzapret-tg check <host> <port> <secret> [dc]")
    exit(2)
}
