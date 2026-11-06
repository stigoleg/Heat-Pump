import CommonCrypto
import Foundation

/// Errors from the local Wi-Fi adapter. `errorDescription` is display text (via `L10n`).
public enum LocalAccessError: Error, Sendable, Equatable, LocalizedError {
    case notEnabled
    case missingHost
    case invalidHost(String)
    case http(status: Int)
    case network(String)
    case badResponse(String)
    case noFrames
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notEnabled: L10n.tr("Local connection is turned off.")
        case .missingHost: L10n.tr("No IP address has been entered for the Wi-Fi adapter.")
        case .invalidHost(let host): L10n.format("“%@” is not a valid IP address on the home network (for example 192.168.1.50).", host)
        case .http(let status): L10n.format("The Wi-Fi adapter answered with HTTP error %lld.", status)
        case .network(let detail): L10n.format("Could not reach the Wi-Fi adapter: %@", detail)
        case .badResponse(let detail): L10n.format("The answer from the Wi-Fi adapter could not be read: %@", detail)
        case .noFrames: L10n.tr("The Wi-Fi adapter answered, but without readings.")
        case .notConfigured: L10n.tr("Local access is not available in this program.")
        }
    }
}

/// What one status read returned, with identifiers already removed.
public struct LocalStatusReply: Sendable, Equatable {
    /// `<CODE><VALUE>` frames as lowercase hex.
    public var frames: [String]
    /// `APP_VER`, e.g. "34.00".
    public var adapterVersion: String?
    /// `RSSI` in dBm.
    public var rssi: Int?
    /// `CONNECT` (ON/OFF): whether the adapter talks to MELCloud. Only read, never set.
    public var cloudConnect: String?

    public init(frames: [String], adapterVersion: String? = nil, rssi: Int? = nil, cloudConnect: String? = nil) {
        self.frames = frames
        self.adapterVersion = adapterVersion
        self.rssi = rssi
        self.cloudConnect = cloudConnect
    }
}

/// Anything that can do one read-only status request (the real client, or a test fake).
public protocol LocalStatusReading: Sendable {
    func readStatus() async throws -> LocalStatusReply
}

/// Read-only client for the Wi-Fi adapter's unofficial `/smart` endpoint on the home network.
///
/// It exposes exactly one operation, `readStatus()`, which always sends the plaintext
/// `<CSV></CSV>`. There is deliberately no way to send any other payload: no `CONNECT`
/// element (the adapter stores it as a persistent setting; OFF silently cuts MELCloud),
/// no CODE/VALUE commands, RESET, ECHONET, unit-info or admin pages.
public struct LocalSmartClient: LocalStatusReading {
    public static let path = "/smart"
    /// The only plaintext this client ever encrypts and sends.
    public static let statusPayload = "<CSV></CSV>"
    public static let timeout: TimeInterval = 5
    /// Responses bigger than this are refused (the real one is about 1 KB).
    static let maxResponseBytes = 64 * 1024
    /// "unregistered" + 4 × NUL: the adapter's static key.
    static let key: [UInt8] = Array("unregistered".utf8) + [0, 0, 0, 0]
    static let blockSize = 16

    public let host: String
    private let transport: any HTTPTransport
    private let makeIV: @Sendable () -> [UInt8]

    /// Throws `.invalidHost` unless `host` is a private IPv4 address.
    public init(
        host: String, transport: any HTTPTransport = URLSessionTransport(session: LocalSmartClient.session),
        makeIV: @escaping @Sendable () -> [UInt8] = LocalSmartClient.randomIV
    ) throws {
        guard let valid = Self.validatedHost(host) else { throw LocalAccessError.invalidHost(host) }
        self.host = valid
        self.transport = transport
        self.makeIV = makeIV
    }

    /// Ephemeral session: no cookies, no cache, short timeouts, and no redirects (a redirect
    /// would re-send the request to another address).
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public static let randomIV: @Sendable () -> [UInt8] = {
        (0..<blockSize).map { _ in UInt8.random(in: 0...255) }
    }

    public func readStatus() async throws -> LocalStatusReply {
        let request = try Self.statusRequest(host: host, iv: makeIV())
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as LocalAccessError {
            throw error
        } catch let error as HeatPumpError {
            if case .network(let detail) = error { throw LocalAccessError.network(detail) }
            throw LocalAccessError.network(error.errorDescription ?? "\(error)")
        } catch {
            throw LocalAccessError.network(error.localizedDescription)
        }
        // Only an answer from the address that was asked counts (redirects are refused, so a
        // 3xx arrives here as an error status).
        guard response.url?.host == host else { throw LocalAccessError.badResponse(L10n.tr("answer from another address")) }
        guard response.statusCode == 200 else { throw LocalAccessError.http(status: response.statusCode) }
        guard data.count <= Self.maxResponseBytes else { throw LocalAccessError.badResponse(L10n.tr("answer too large")) }
        return try Self.parseResponse(data)
    }

    // MARK: Request

    /// The status request. The payload is always `statusPayload`; nothing else can be sent.
    static func statusRequest(host: String, iv: [UInt8]) throws -> URLRequest {
        guard let valid = validatedHost(host), let url = URL(string: "http://\(valid)\(path)") else {
            throw LocalAccessError.invalidHost(host)
        }
        guard iv.count == blockSize else { throw LocalAccessError.badResponse(L10n.tr("invalid IV")) }
        let encrypted = try encrypt(Array(statusPayload.utf8), iv: iv)
        let body = #"<?xml version="1.0" encoding="UTF-8"?><ESV>"# + Data(iv + encrypted).base64EncodedString() + "</ESV>"
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        // "chrset" (sic) is what the official app sends.
        request.setValue("text/plain;chrset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// Accepts dotted IPv4 addresses in the private ranges (10/8, 172.16/12, 192.168/16) only,
    /// so the client can never be pointed at anything outside the home network.
    public static func validatedHost(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        let isPrivate =
            octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        guard isPrivate, octets[3] != 0, octets[3] != 255 else { return nil }
        return octets.map(String.init).joined(separator: ".")
    }

    // MARK: Response

    /// `<ESV>base64</ESV>` → decrypted XML → identifiers removed → frames and adapter fields.
    static func parseResponse(_ data: Data) throws -> LocalStatusReply {
        let text = String(decoding: data, as: UTF8.self)
        guard let payload = element("ESV", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let encrypted = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        else { throw LocalAccessError.badResponse(L10n.tr("missing <ESV>")) }
        guard let plain = decrypt(Array(encrypted)) else { throw LocalAccessError.badResponse(L10n.tr("could not decrypt")) }
        let xml = redacted(String(decoding: plain, as: UTF8.self))
        return reply(fromDecrypted: xml)
    }

    /// Removes elements that identify the adapter (MAC, serial number, profile codes) right
    /// after decryption, so they never reach logs, the database or the UI.
    static func redacted(_ xml: String) -> String {
        var text = xml
        for name in ["MAC", "SERIAL", "PROFILECODE"] {
            while let open = text.range(of: "<\(name)>"),
                let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
            // A self-closing or unterminated tag is dropped to the end of the text.
            if let open = text.range(of: "<\(name)>") { text.removeSubrange(open.lowerBound..<text.endIndex) }
        }
        return text
    }

    static func reply(fromDecrypted xml: String) -> LocalStatusReply {
        var frames: [String] = []
        if let code = element("CODE", in: xml) {
            var rest = code[...]
            while let open = rest.range(of: "<VALUE>"), let close = rest.range(of: "</VALUE>", range: open.upperBound..<rest.endIndex) {
                let hex = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if hex.count.isMultiple(of: 2), hex.count <= 256, hex.allSatisfy(\.isHexDigit) { frames.append(hex) }
                rest = rest[close.upperBound...]
            }
        }
        let version = element("APP_VER", in: xml)?.trimmingCharacters(in: .whitespaces)
        let rssi = element("RSSI", in: xml).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let connect = element("CONNECT", in: xml)?.trimmingCharacters(in: .whitespaces).uppercased()
        return LocalStatusReply(
            frames: frames,
            adapterVersion: version.flatMap { $0.count <= 12 && $0.allSatisfy { $0.isNumber || $0 == "." } ? $0 : nil },
            rssi: rssi.flatMap { (-120...0).contains($0) ? $0 : nil },
            cloudConnect: connect.flatMap { ["ON", "OFF"].contains($0) ? $0 : nil })
    }

    /// Text between `<name>` and `</name>` (first occurrence), tolerant of surrounding noise.
    static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
            let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// `<ESV>base64(iv ‖ ciphertext)</ESV>` for `xml`: the adapter's reply format (simulation and tests).
    static func envelope(_ xml: String, iv: [UInt8]) throws -> Data {
        let encrypted = try encrypt(Array(xml.utf8), iv: iv)
        return Data(("<ESV>" + Data(iv + encrypted).base64EncodedString() + "</ESV>").utf8)
    }

    /// Plaintext of a request body produced by `statusRequest` (simulation and tests).
    static func decryptRequestBody(_ body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let payload = element("ESV", in: text), let data = Data(base64Encoded: payload),
            let plain = decrypt(Array(data))
        else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: Crypto (AES-128-CBC, ISO/IEC 7816-4 padding)

    static func encrypt(_ plaintext: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard let out = cbc(CCOperation(kCCEncrypt), pad(plaintext), iv: iv) else {
            throw LocalAccessError.badResponse(L10n.tr("encryption failed"))
        }
        return out
    }

    /// `ivAndCiphertext` = 16-byte IV followed by the ciphertext. Strips ISO 7816-4 padding,
    /// falling back to trailing NULs as the adapter sometimes pads that way.
    static func decrypt(_ ivAndCiphertext: [UInt8]) -> [UInt8]? {
        guard ivAndCiphertext.count > blockSize, (ivAndCiphertext.count - blockSize).isMultiple(of: blockSize) else { return nil }
        let iv = Array(ivAndCiphertext.prefix(blockSize))
        guard let plain = cbc(CCOperation(kCCDecrypt), Array(ivAndCiphertext.dropFirst(blockSize)), iv: iv) else { return nil }
        if let unpadded = unpad(plain) { return unpadded }
        var trimmed = plain
        while trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    static func pad(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes + [0x80]
        while !out.count.isMultiple(of: blockSize) { out.append(0) }
        return out
    }

    static func unpad(_ bytes: [UInt8]) -> [UInt8]? {
        guard let index = bytes.lastIndex(where: { $0 != 0 }), bytes[index] == 0x80, bytes.count - index <= blockSize else {
            return nil
        }
        return Array(bytes[..<index])
    }

    static func cbc(_ operation: CCOperation, _ input: [UInt8], iv: [UInt8]) -> [UInt8]? {
        guard input.count.isMultiple(of: blockSize), iv.count == blockSize else { return nil }
        var output = [UInt8](repeating: 0, count: input.count + blockSize)
        var moved = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            CCCrypt(
                operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(0),  // CBC, no padding
                key, key.count, iv, input, input.count, out.baseAddress, outputCount, &moved)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(output.prefix(moved))
    }
}

/// Refuses every HTTP redirect: the 3xx response is returned to the caller instead.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
