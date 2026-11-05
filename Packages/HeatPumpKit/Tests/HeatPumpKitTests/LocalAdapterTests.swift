import CommonCrypto
import Foundation
import Synchronization
import Testing
@testable import HeatPumpKit

/// Real frames captured from the user's adapter (no identifiers in them).
enum LocalFixture {
    static let frames = [
        "fc7b013010c9030020001417f58c25a0be94bea0be79",
        "fc7b013010cda0bea0bea0be1c11020000000000002e",
        "fc62013010020000010918030000008caf28000000d3",
        "fc62013010030000100092b4b1fe420015d49f00008b",
        "fc6201301004000000800000000000000000000000d9",
        "fc620130100500000000000000000000000000000058",
        "fc6201301006000000000004a1f80000420000000078",
        "fc620130100900000001000000000000000000000053",
    ]

    /// Decrypted reply in the adapter's format, with made-up identifiers that must be stripped.
    static func replyXML(frames: [String] = frames, connect: String = "ON") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><LSV><MAC>00:00:5E:00:53:99</MAC><SERIAL>FAKE1234567</SERIAL>"
            + "<CONNECT>\(connect)</CONNECT><STATUS>NORMAL</STATUS><DATDATE>2026/11/05 10:00:00</DATDATE>"
            + "<ECHONET>OFF</ECHONET><LED><LED1>1:1,0:0</LED1></LED><APP_VER>34.00</APP_VER><RSSI>-54</RSSI>"
            + "<SSL_LIMIT>20271231</SSL_LIMIT><PROFILECODE><VALUE>0123456789abcdef</VALUE></PROFILECODE>"
            + "<CODE>" + frames.map { "<VALUE>\($0)</VALUE>" }.joined() + "</CODE></LSV>"
    }
}

/// Answers like the adapter: decrypts the request, records its plaintext, replies with `xml`.
final class FakeAdapterTransport: HTTPTransport {
    private let state = Mutex<(requests: [URLRequest], plaintexts: [String], xml: String, status: Int, error: LocalAccessError?)>(
        ([], [], LocalFixture.replyXML(), 200, nil))

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var plaintexts: [String] { state.withLock { $0.plaintexts } }
    func reply(xml: String) { state.withLock { $0.xml = xml } }
    func fail(_ error: LocalAccessError?) { state.withLock { $0.error = error } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (xml, status, error) = state.withLock { s in
            s.requests.append(request)
            s.plaintexts.append(request.httpBody.flatMap(LocalSmartClient.decryptRequestBody) ?? "<undecryptable>")
            return (s.xml, s.status, s.error)
        }
        if let error { throw error }
        let body = try LocalSmartClient.envelope(xml, iv: Array(repeating: 7, count: 16))
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Local adapter: crypto, request and frames")
struct LocalAdapterTests {
    let fixedIV: [UInt8] = Array(0..<16)
    let date = Date(timeIntervalSince1970: 1_793_872_800)

    @Test func cryptoRoundTripWithFixedIV() throws {
        let plain = Array("<CSV></CSV>".utf8)
        let encrypted = try LocalSmartClient.encrypt(plain, iv: fixedIV)
        #expect(encrypted.count == 16)
        // Same input and IV give the same ciphertext (deterministic, no hidden randomness).
        #expect(try LocalSmartClient.encrypt(plain, iv: fixedIV) == encrypted)
        #expect(LocalSmartClient.decrypt(fixedIV + encrypted) == plain)
        // Exactly one block of input still gets a full padding block (ISO 7816-4).
        let sixteen = Array("0123456789abcdef".utf8)
        let padded = try LocalSmartClient.encrypt(sixteen, iv: fixedIV)
        #expect(padded.count == 32)
        #expect(LocalSmartClient.decrypt(fixedIV + padded) == sixteen)
    }

    @Test func isoPaddingAndNulFallback() {
        #expect(LocalSmartClient.pad([1, 2, 3]) == [1, 2, 3, 0x80] + Array(repeating: 0, count: 12))
        #expect(LocalSmartClient.unpad([1, 2, 0x80, 0, 0]) == [1, 2])
        #expect(LocalSmartClient.unpad([1, 2, 0, 0]) == nil)
        // Without ISO padding the decrypter strips trailing NULs instead.
        let nulPadded = Array("<CSV></CSV>".utf8) + [0, 0, 0, 0, 0]
        let cipher = LocalSmartClient.cbc(CCOperation(kCCEncrypt), nulPadded, iv: fixedIV)
        #expect(cipher.flatMap { LocalSmartClient.decrypt(fixedIV + $0) } == Array("<CSV></CSV>".utf8))
        #expect(LocalSmartClient.decrypt([1, 2, 3]) == nil)
    }

    /// Guard: the only plaintext ever sent is `<CSV></CSV>` (no CONNECT element), to `/smart`.
    @Test func statusRequestIsExactlyCSVToSmart() async throws {
        let request = try LocalSmartClient.statusRequest(host: "192.168.10.83", iv: fixedIV)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://192.168.10.83/smart")
        #expect(request.url?.path == "/smart")
        #expect(request.timeoutInterval == 5)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain;chrset=UTF-8")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?><ESV>"#))
        #expect(request.httpBody.flatMap(LocalSmartClient.decryptRequestBody) == "<CSV></CSV>")

        let transport = FakeAdapterTransport()
        let client = try LocalSmartClient(host: "192.168.10.83", transport: transport)
        _ = try await client.readStatus()
        _ = try await client.readStatus()
        #expect(transport.plaintexts == ["<CSV></CSV>", "<CSV></CSV>"])
        #expect(transport.plaintexts.allSatisfy { !$0.contains("CONNECT") })
        #expect(transport.requests.allSatisfy { $0.url?.path == "/smart" && $0.httpMethod == "POST" })
        #expect(LocalSmartClient.statusPayload == "<CSV></CSV>")
    }

    @Test func onlyPrivateIPv4HostsAreAccepted() {
        #expect(LocalSmartClient.validatedHost("192.168.10.83") == "192.168.10.83")
        #expect(LocalSmartClient.validatedHost(" 10.0.0.7 ") == "10.0.0.7")
        #expect(LocalSmartClient.validatedHost("172.20.1.2") == "172.20.1.2")
        for bad in ["8.8.8.8", "172.32.0.1", "192.168.1.255", "192.168.1.0", "example.com", "192.168.1.5/admin",
                    "192.168.1.5:8080", "192.168.1", "", "192.168.01x.5", "1.2.3.4.5"] {
            #expect(LocalSmartClient.validatedHost(bad) == nil, "\(bad)")
        }
        #expect(throws: LocalAccessError.invalidHost("8.8.8.8")) { try LocalSmartClient(host: "8.8.8.8") }
    }

    @Test func decryptsCapturedFormatAndStripsIdentifiers() throws {
        let body = try LocalSmartClient.envelope(LocalFixture.replyXML(), iv: fixedIV)
        let reply = try LocalSmartClient.parseResponse(body)
        #expect(reply.frames == LocalFixture.frames)
        #expect(reply.adapterVersion == "34.00")
        #expect(reply.rssi == -54)
        #expect(reply.cloudConnect == "ON")
        let redacted = LocalSmartClient.redacted(LocalFixture.replyXML())
        #expect(!redacted.contains("FAKE1234567"))
        #expect(!redacted.contains("00:00:5E"))
        #expect(!redacted.contains("0123456789abcdef"))
        #expect(redacted.contains("<CODE>"))
        // PROFILECODE also holds <VALUE> elements; they must not be taken as frames.
        #expect(!reply.frames.contains("0123456789abcdef"))
    }

    @Test func badResponsesThrow() async throws {
        #expect(throws: LocalAccessError.self) { try LocalSmartClient.parseResponse(Data("<html>nope</html>".utf8)) }
        #expect(throws: LocalAccessError.self) { try LocalSmartClient.parseResponse(Data("<ESV>AAAA</ESV>".utf8)) }
        let transport = FakeAdapterTransport()
        transport.fail(.network("timeout"))
        let client = try LocalSmartClient(host: "192.168.1.20", transport: transport)
        await #expect(throws: LocalAccessError.network("timeout")) { try await client.readStatus() }
    }

    @Test func checksumMatchesAllFixtures() throws {
        for hex in LocalFixture.frames {
            let data = try #require(CN105Parser.bytes(hex: hex))
            #expect(throws: Never.self) { try CN105Parser.validate(data) }
            #expect(CN105Parser.checksum(data[1..<(data.count - 1)]) == data.last)
        }
    }

    @Test func checksumAndHeaderFailuresAreRejected() throws {
        var data = try #require(CN105Parser.bytes(hex: LocalFixture.frames[2]))
        data[16] ^= 0x01
        #expect(throws: CN105Parser.FrameError.badChecksum) { try CN105Parser.validate(data) }
        var header = try #require(CN105Parser.bytes(hex: LocalFixture.frames[2]))
        header[0] = 0xFD
        #expect(throws: CN105Parser.FrameError.badHeader) { try CN105Parser.validate(header) }
        #expect(throws: CN105Parser.FrameError.tooShort) { try CN105Parser.validate([0xFC, 0x62]) }
        #expect(CN105Parser.bytes(hex: "fz") == nil)
        let corrupt = data.map { String(format: "%02x", $0) }.joined()
        let result = CN105Parser.sample(frames: [corrupt, "zz", LocalFixture.frames[3]], at: date)
        #expect(result.rejected == 2)
        #expect(result.used == 1)
        #expect(result.sample.setTemperature == nil)  // the corrupt 0x02 frame was not used
        #expect(result.sample.roomTemperature == 26.0)
    }

    @Test func fixtureFramesDecode() {
        let result = CN105Parser.sample(frames: LocalFixture.frames, at: date)
        let s = result.sample
        #expect(result.used == 4)  // 0x02, 0x03, 0x04, 0x06; 0x05, 0x09 and 0x7B ignored
        #expect(result.rejected == 0)
        #expect(s.power == true)
        #expect(s.mode == .heat)
        #expect(s.iSee == true)
        #expect(s.setTemperature == 23.5)
        #expect(s.fanSpeed == 3)
        #expect(s.vaneVertical == .auto)
        #expect(s.vaneHorizontal == .swing)
        #expect(s.roomTemperature == 26.0)
        #expect(s.outdoorTemperature == 9.0)
        #expect(s.roomTemperature2 == 24.5)
        #expect(s.errorCode == 0x8000)
        #expect(s.hasError == false)
        #expect(s.compressorHz == 0)
        #expect(s.operating == false)
        #expect(s.isRunning == false)
        #expect(s.powerW == 4)
        #expect(s.energyKWh == 4146.4)
    }

    @Test func fanAndVaneMappingKeepsUnknownRaw() {
        var s = LocalSample(timestamp: date)
        // fan 5 → speed 4, fan 6 → 5, horizontal 6 (left-centre) has no MELCloud value.
        let frame = CN105Parser.frame(group: 0x02, payload: [8: 1, 9: 0x03, 11: 5, 12: 7, 15: 0x06, 16: 0x80 + 44])
        CN105Parser.applyGeneral(CN105Parser.bytes(hex: frame)!, to: &s)
        #expect(s.mode == .cool)
        #expect(s.fanSpeed == 4)
        #expect(s.vaneVertical == .swing)
        #expect(s.vaneHorizontal == nil)
        #expect(s.vaneHorizontalRaw == 6)
        #expect(s.setTemperature == 22)
        let unknown = CN105Parser.frame(group: 0x02, payload: [9: 0x05, 10: 10, 11: 4])
        CN105Parser.applyGeneral(CN105Parser.bytes(hex: unknown)!, to: &s)
        #expect(s.power == false)
        #expect(s.mode == nil && s.modeRaw == 5)
        #expect(s.fanSpeed == nil && s.fanRaw == 4)
        #expect(s.setTemperature == 21)  // coarse 31 - 10 when the fine byte is 0
        // Outdoor 0x01 means "unit off": no outdoor temperature.
        let off = CN105Parser.frame(group: 0x03, payload: [8: 10, 10: 0x01, 11: 0])
        CN105Parser.applySensors(CN105Parser.bytes(hex: off)!, to: &s)
        #expect(s.outdoorTemperature == nil)
        #expect(s.roomTemperature == 20)
    }

    @Test func builtFramesValidate() throws {
        let hex = CN105Parser.frame(group: 0x06, payload: [8: 38, 9: 1, 10: 0x02, 11: 0x58, 12: 0xA1, 13: 0xF8])
        let s = CN105Parser.sample(frames: [hex], at: date).sample
        #expect(s.compressorHz == 38 && s.operating == true && s.powerW == 600 && s.energyKWh == 4146.4)
    }

    @Test func counterWrapAndImpossibleDeltas() {
        #expect(LocalCounter.delta(from: 4146.4, to: 4146.9, seconds: 3600) == 0.5)
        #expect(LocalCounter.delta(from: 6553.4, to: 0.1, seconds: 600) == 0.3)
        #expect(LocalCounter.delta(from: 4146.4, to: 100, seconds: 600) == nil)  // reset, not a wrap
        #expect(LocalCounter.delta(from: 100, to: 120, seconds: 600) == nil)  // 120 kW is impossible
        let t0 = date
        let hourly = LocalCounter.hourly(
            [(t0, 6553.0), (t0.addingTimeInterval(1800), 6553.4), (t0.addingTimeInterval(3600), 0.2),
             (t0.addingTimeInterval(3 * 3600 + 3600), 1.0)],  // 3 h gap: not exact, skipped
            timeZone: .gmt)
        let hour = hourly[t0]
        #expect(hour.map { abs($0.kWh - 0.8) < 1e-9 } == true)
        #expect(hour?.covered == 3600)
        #expect(hourly.count == 1)
    }

    @Test func compressorStartsPerHour() {
        // One reading per minute for two hours; the compressor runs 10 min, stops 5 min (4 starts/h).
        var samples: [LocalSample] = []
        for minute in 0..<120 {
            var s = LocalSample(timestamp: date.addingTimeInterval(Double(minute) * 60))
            let running = minute % 15 >= 5
            s.operating = running
            s.compressorHz = running ? 40 : 0
            samples.append(s)
        }
        let hours = CompressorCycles.startsPerHour(samples, timeZone: .gmt)
        #expect(hours.map(\.starts) == [4, 4])
        #expect(hours.first?.observedMinutes == 59)
        // A gap over 5 minutes is not compared.
        var gap = samples
        gap.removeSubrange(3...12)
        #expect(CompressorCycles.startsPerHour(gap, timeZone: .gmt).first?.starts == 3)
    }
}
