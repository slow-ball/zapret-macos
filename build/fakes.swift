// The fake packets of the strategies (src/nfqws/bin), made here instead of taken from elsewhere: the engine
// sends them before the real ones, so the provider's filter reads a harmless site in them.
//
//   swift build/fakes.swift <src/nfqws>            every file the strategies name, the others go
//   swift build/fakes.swift <src/nfqws> --check    the files are what this makes (Check)
//   swift build/fakes.swift selftest               QUIC keys against RFC 9001, appendix A
//
// By the name of the file: tls_clienthello_<site>.bin is a ClientHello of Chrome for the site (dots as "_"),
// quic_initial_<site>.bin a QUIC v1 Initial with such a ClientHello, encrypted as RFC 9001 says (a filter
// decrypts it to read the name), stun*.bin a STUN Binding Request of WebRTC; any other UDP fake a QUIC Initial
// too. A few names don't spell their site (knownSites); one renamed by build/import-windows.py gets
// www.google.com. The randomness comes
// from the name: every run makes the same bytes.

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - bytes

/// random bytes that follow from a seed: SHA-256 of the seed and a counter
struct Seeded {
    private var seed: [UInt8]
    private var counter: UInt32 = 0
    private var pool: [UInt8] = []

    init(_ seed: String) { self.seed = Array(seed.utf8) }

    mutating func bytes(_ n: Int) -> [UInt8] {
        while pool.count < n {
            var block = seed
            withUnsafeBytes(of: counter.bigEndian) { block += $0 }
            counter += 1
            pool += Array(SHA256.hash(data: block))
        }
        defer { pool.removeFirst(n) }
        return Array(pool.prefix(n))
    }

    /// a GREASE value of RFC 8701: 0x0a0a, 0x1a1a … 0xfafa
    mutating func grease() -> UInt16 {
        let b = UInt16(bytes(1)[0] & 0xf0) | 0x0a
        return b << 8 | b
    }
}

func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func u24(_ v: Int) -> [UInt8] { [UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
func u32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

/// a QUIC variable-length integer of two bytes (values below 16384) or one (below 64)
func varint(_ v: Int) -> [UInt8] { v < 64 ? [UInt8(v)] : [UInt8(0x40 | v >> 8), UInt8(v & 0xff)] }

func vector8(_ b: [UInt8]) -> [UInt8] { [UInt8(b.count)] + b }
func vector16(_ b: [UInt8]) -> [UInt8] { u16(b.count) + b }

func ext(_ type: Int, _ body: [UInt8]) -> [UInt8] { u16(type) + vector16(body) }

// MARK: - TLS ClientHello

/// the ClientHello of Chrome (TLS 1.3, with GREASE), a handshake message; for QUIC without the session id and
/// the TCP-only extensions, with ALPN h3 and transport parameters
func clientHello(_ sni: String, quic: Bool, _ rnd: inout Seeded) -> [UInt8] {
    let g = rnd.grease(), g2 = rnd.grease(), g3 = rnd.grease()
    let suites: [Int] =
        quic ? [0x1301, 0x1302, 0x1303]
        : [Int(g), 0x1301, 0x1302, 0x1303, 0xc02b, 0xc02f, 0xc02c, 0xc030, 0xcca9, 0xcca8, 0xc013, 0xc014,
            0x009c, 0x009d, 0x002f, 0x0035]
    let host = Array(sni.utf8)
    var exts: [UInt8] = []
    if !quic { exts += ext(Int(g2), []) }
    exts += ext(0x0000, vector16([0] + vector16(host)))
    exts += ext(0x0017, [])
    if !quic { exts += ext(0xff01, [0]) }
    exts += ext(0x000a, vector16((quic ? [] : u16(Int(g3))) + u16(0x001d) + u16(0x0017) + u16(0x0018)))
    if !quic {
        exts += ext(0x000b, vector8([0]))
        exts += ext(0x0023, [])
    }
    let alpn = quic ? vector8(Array("h3".utf8)) : vector8(Array("h2".utf8)) + vector8(Array("http/1.1".utf8))
    exts += ext(0x0010, vector16(alpn))
    exts += ext(0x0005, [1, 0, 0, 0, 0])
    let sigalgs = [0x0403, 0x0804, 0x0401, 0x0503, 0x0805, 0x0501, 0x0806, 0x0601]
    exts += ext(0x000d, vector16(sigalgs.flatMap(u16)))
    exts += ext(0x0012, [])
    let share = (quic ? [] : u16(Int(g3)) + vector16([0])) + u16(0x001d) + vector16(rnd.bytes(32))
    exts += ext(0x0033, vector16(share))
    exts += ext(0x002d, vector8([1]))
    exts += ext(0x002b, vector8((quic ? [] : u16(Int(g))) + u16(0x0304) + (quic ? [] : u16(0x0303))))
    exts += ext(0x001b, vector8(u16(0x0002)))
    if quic {
        // initial_max_data, initial_max_stream_data_bidi_local/remote/uni, initial_max_streams_bidi/uni,
        // max_idle_timeout, max_udp_payload_size, initial_source_connection_id (empty: no source id)
        var tp: [UInt8] = []
        for (id, v) in [(0x04, 15_728_640), (0x05, 6_291_456), (0x06, 6_291_456), (0x07, 6_291_456), (0x08, 100),
            (0x09, 103), (0x01, 30000), (0x03, 1472)]
        {
            let value: [UInt8] = v < 16384 ? varint(v) : [0x80 | UInt8(v >> 24 & 0x3f)] + u24(v)
            tp += varint(id) + varint(value.count) + value
        }
        tp += varint(0x0f) + varint(0)
        exts += ext(0x0039, tp)
    } else {
        exts += ext(Int(g2 ^ 0x1010), [0])
    }
    var body = u16(0x0303) + rnd.bytes(32) + (quic ? [0] : vector8(rnd.bytes(32)))
    body += vector16(suites.flatMap(u16)) + vector8([0])
    // the padding of BoringSSL: a hello of 256 to 511 bytes grows to 512
    let unpadded = 4 + body.count + 2 + exts.count
    if !quic && unpadded > 0xff && unpadded < 0x200 {
        exts += ext(0x0015, [UInt8](repeating: 0, count: max(0x200 - unpadded - 4, 1)))
    }
    body += vector16(exts)
    return [1] + u24(body.count) + body
}

/// the hello in a TLS record, as it goes over TCP
func tlsRecord(_ sni: String, _ rnd: inout Seeded) -> [UInt8] {
    let hello = clientHello(sni, quic: false, &rnd)
    return [0x16, 0x03, 0x01] + u16(hello.count) + hello
}

// MARK: - QUIC Initial (RFC 9000, 9001)

func hkdfExpandLabel(_ secret: SymmetricKey, _ label: String, _ length: Int) -> SymmetricKey {
    let full = Array(("tls13 " + label).utf8)
    let info = u16(length) + vector8(full) + [0]
    return HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length)
}

struct InitialKeys {
    let key: SymmetricKey, iv: [UInt8], hp: [UInt8]

    init(dcid: [UInt8]) {
        let salt: [UInt8] = [
            0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb,
            0x7f, 0x0a,
        ]
        let initial = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: dcid), salt: salt)
        let client = hkdfExpandLabel(SymmetricKey(data: Array(initial)), "client in", 32)
        key = hkdfExpandLabel(client, "quic key", 16)
        iv = hkdfExpandLabel(client, "quic iv", 12).withUnsafeBytes { Array($0) }
        hp = hkdfExpandLabel(client, "quic hp", 16).withUnsafeBytes { Array($0) }
    }
}

func aesBlock(_ key: [UInt8], _ block: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16 + kCCBlockSizeAES128)
    var moved = 0
    CCCrypt(
        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count, nil,
        block, 16, &out, out.count, &moved)
    return Array(out.prefix(16))
}

/// a client's first packet: the hello in a CRYPTO frame, padded to `size` bytes
func quicInitial(_ sni: String, size: Int, _ rnd: inout Seeded) -> [UInt8] {
    let dcid = rnd.bytes(8)
    let keys = InitialKeys(dcid: dcid)
    let hello = clientHello(sni, quic: true, &rnd)
    let pn: UInt32 = 1
    // the header: long, Initial, a packet number of 4 bytes; version 1; no source id, no token
    var header: [UInt8] = [0xc3] + u32(1) + vector8(dcid) + [0] + varint(0)
    let fixed = header.count + 2 + 4 + 16
    var payload = [0x06] + varint(0) + varint(hello.count) + hello
    payload += [UInt8](repeating: 0, count: max(size - fixed - payload.count, 0))
    header += [0x40 | UInt8((4 + payload.count + 16) >> 8), UInt8((4 + payload.count + 16) & 0xff)] + u32(pn)
    var nonce = keys.iv
    for (i, b) in u32(pn).enumerated() { nonce[8 + i] ^= b }
    let sealed = try! AES.GCM.seal(payload, using: keys.key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
    var packet = header + Array(sealed.ciphertext) + Array(sealed.tag)
    // header protection: a mask from the ciphertext 4 bytes after the start of the packet number
    let pnOffset = header.count - 4
    let mask = aesBlock(keys.hp, Array(packet[pnOffset + 4..<pnOffset + 20]))
    packet[0] ^= mask[0] & 0x0f
    for i in 0..<4 { packet[pnOffset + i] ^= mask[1 + i] }
    return packet
}

// MARK: - STUN (RFC 8489, 8445)

func crc32(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for b in data {
        crc ^= UInt32(b)
        for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0xedb8_8320 : crc >> 1 }
    }
    return ~crc
}

func attr(_ type: Int, _ value: [UInt8]) -> [UInt8] {
    u16(type) + u16(value.count) + value + [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
}

/// a Binding Request of an ICE check, as a browser's WebRTC sends it; `user` long fragments of the username
func stun(user: Int, _ rnd: inout Seeded) -> [UInt8] {
    let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/".utf8)
    func fragment(_ n: Int, _ r: inout Seeded) -> [UInt8] { r.bytes(n).map { letters[Int($0) % letters.count] } }
    let txid = rnd.bytes(12)
    var attrs = attr(0x0006, fragment(user, &rnd) + Array(":".utf8) + fragment(4, &rnd))
    attrs += attr(0xc057, [0, 1, 0, 10])
    attrs += attr(0x802a, rnd.bytes(8))
    attrs += attr(0x0024, u32(0x6e7f_1eff))
    func message(_ extra: Int) -> [UInt8] { u16(0x0001) + u16(attrs.count + extra) + u32(0x2112_a442) + txid + attrs }
    // the integrity counts the length with itself in it, the fingerprint with itself too
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message(24), using: SymmetricKey(data: rnd.bytes(16)))
    attrs += attr(0x0008, Array(mac))
    attrs += attr(0x8028, u32(crc32(message(8)) ^ 0x5354_554e))
    return message(0)
}

// MARK: - files

/// fakes whose name doesn't spell their site: the site the strategies count on (one a provider lets through)
let knownSites = [
    "tls_clienthello_sochi_park": "staging-sochi-park.predict.mail.ru",
    "ACTIVE_DISCORD_UDP": "steamcommunity.com",
    "ACTIVE_GAME_UDP": "4pda.to",
]

/// the bytes of a fake by its file name
func fake(_ name: String) -> [UInt8] {
    var rnd = Seeded(name)
    let base = name.replacingOccurrences(of: ".bin", with: "")
    func site(_ prefix: String) -> String {
        if let known = knownSites[base] { return known }
        let rest = String(base.dropFirst(prefix.count))
        // a renamed one: eight hex digits instead of the site
        return rest.contains("_") ? rest.replacingOccurrences(of: "_", with: ".") : "www.google.com"
    }
    if base.hasPrefix("tls_clienthello_") { return tlsRecord(site("tls_clienthello_"), &rnd) }
    if base.hasPrefix("quic_initial_") { return quicInitial(site("quic_initial_"), size: 1200, &rnd) }
    if base.hasPrefix("stun") { return stun(user: base == "stun" ? 4 : 24, &rnd) }
    return quicInitial(site(base), size: 1200, &rnd)
}

/// the fakes the strategies name: @BASE@/bin/<name> in the files of src/nfqws
func named(in root: URL) -> Set<String> {
    var names = Set<String>()
    let pattern = try! NSRegularExpression(pattern: "@BASE@/bin/([A-Za-z0-9_.-]+\\.bin)")
    for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
        guard url.pathExtension == "conf" || url.lastPathComponent.hasSuffix(".conf.in"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { continue }
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            names.insert((text as NSString).substring(with: m.range(at: 1)))
        }
    }
    return names
}

func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

func selftest() -> Bool {
    let k = InitialKeys(dcid: hex("8394c8f03e515708"))
    let key = k.key.withUnsafeBytes { Array($0) }
    let ok =
        key == hex("1f369613dd76d5467730efcbe3b1a22d") && k.iv == hex("fa044b2f42a3fd3b46fb255c")
        && k.hp == hex("9f50449e04a0e810283a1e9933adedd2")
    // the mask of the sample in appendix A.2
    let mask = aesBlock(k.hp, hex("d1b1c98dd7689fb8ec11d242b123dc9b"))
    let ok2 = Array(mask.prefix(5)) == hex("437b9aec36")
    print(ok && ok2 ? "OK: ключи QUIC совпадают с RFC 9001" : "FAIL: ключи QUIC не совпадают с RFC 9001")
    return ok && ok2
}

let args = CommandLine.arguments.dropFirst()
if args.first == "selftest" { exit(selftest() ? 0 : 1) }
guard let dir = args.first else {
    print("swift build/fakes.swift <src/nfqws> [--check] | selftest")
    exit(2)
}
let root = URL(fileURLWithPath: dir)
let bin = root.appendingPathComponent("bin")
let check = args.contains("--check")
let names = named(in: root)
var bad = 0
try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
for name in names.sorted() {
    let url = bin.appendingPathComponent(name)
    let want = Data(fake(name))
    if check {
        if (try? Data(contentsOf: url)) != want {
            print("не то: bin/\(name)")
            bad += 1
        }
    } else {
        try! want.write(to: url)
    }
}
for url in (try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
where url.pathExtension == "bin" && !names.contains(url.lastPathComponent) {
    if check {
        print("лишний: bin/\(url.lastPathComponent)")
        bad += 1
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}
print(check ? (bad == 0 ? "OK: фейков \(names.count), все свои" : "FAIL: \(bad)") : "фейков: \(names.count)")
exit(bad == 0 ? 0 : 1)
