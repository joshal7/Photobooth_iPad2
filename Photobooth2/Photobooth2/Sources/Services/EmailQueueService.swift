import Foundation
import Combine
import Network
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Email Queue Models & Transport Protocol

nonisolated enum EmailJobStatus: String, Codable, Equatable, Sendable {
    case pending
    case sending
    case failedPermanent
}

nonisolated struct EmailQueueItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let recipientEmail: String
    let galleryURLString: String
    let subject: String
    let attachmentFilenames: [String]
    let createdAt: Date
    var status: EmailJobStatus
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?
}

nonisolated struct EmailQueueManifestDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion: Int = 1
    static let defaultFilename: String = "email_queue_manifest.json"
    
    var schemaVersion: Int = EmailQueueManifestDocument.currentSchemaVersion
    var totalSentCount: Int = 0
    var items: [EmailQueueItem] = []
}

nonisolated struct EmailAttachmentPayload: Equatable, Sendable {
    let filename: String
    let contentType: String
    let data: Data
}

nonisolated struct EmailDeliveryRequest: Equatable, Sendable {
    let jobID: UUID
    let idempotencyKey: String
    let from: String
    let to: String
    let subject: String
    let htmlBody: String
    let textBody: String
    let attachments: [EmailAttachmentPayload]
    let apiKey: String
}

nonisolated enum EmailSendOutcome: Equatable, Sendable {
    case sent(providerMessageID: String)
    case transientFailure(reason: String, retryAfterSec: TimeInterval?)
    case configurationPaused(reason: String)
    case permanentRecipientFailure(reason: String)
}

nonisolated struct EmailConfirmationCopy: Equatable, Sendable {
    let title: String
    let subtitle: String
    let isOnline: Bool
    let isConfigured: Bool
    
    nonisolated init(title: String, subtitle: String, isOnline: Bool, isConfigured: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.isOnline = isOnline
        self.isConfigured = isConfigured
    }
}

protocol EmailTransport: AnyObject, Sendable {
    nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome
}

// MARK: - Production Resend HTTPS Transport

final class ResendEmailTransport: EmailTransport, @unchecked Sendable {
    private nonisolated let session: URLSession
    private nonisolated let endpointURL: URL
    
    nonisolated init(
        endpointURL: URL = URL(string: "https://api.resend.com/emails")!,
        requestTimeoutSec: TimeInterval = 20.0,
        resourceTimeoutSec: TimeInterval = 45.0,
        protocolClasses: [AnyClass]? = nil
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeoutSec
        config.timeoutIntervalForResource = resourceTimeoutSec
        if let protocolClasses = protocolClasses {
            config.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: config)
        self.endpointURL = endpointURL
    }
    
    nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome {
        let trimmedKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .configurationPaused(reason: "Email credentials not configured — open Settings > Sharing to enter your Gmail App Password or Resend API Key")
        }
        
        let trimmedFrom = request.from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty else {
            return .configurationPaused(reason: "Sender email address not configured in Settings")
        }
        
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        
        let bodyData: Data? = autoreleasepool {
            let encodedAttachments: [[String: String]] = request.attachments.map { att in
                [
                    "filename": att.filename,
                    "content": att.data.base64EncodedString()
                ]
            }
            
            let payload: [String: Any] = [
                "from": trimmedFrom,
                "to": [request.to],
                "subject": request.subject,
                "html": request.htmlBody,
                "text": request.textBody,
                "attachments": encodedAttachments
            ]
            
            return try? JSONSerialization.data(withJSONObject: payload, options: [])
        }
        
        guard let serializedBody = bodyData else {
            return .permanentRecipientFailure(reason: "Failed to serialize email JSON payload")
        }
        urlRequest.httpBody = serializedBody
        
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure(reason: "Non-HTTP network response", retryAfterSec: nil)
            }
            
            let statusCode = httpResponse.statusCode
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            
            if (200...299).contains(statusCode) {
                // Guard against captive portals returning HTTP 200 OK with an HTML login page
                if contentType.contains("text/html") {
                    return .transientFailure(reason: "Captive portal HTML response detected", retryAfterSec: nil)
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let messageID = json["id"] as? String, !messageID.isEmpty {
                    return .sent(providerMessageID: messageID)
                }
                return .transientFailure(reason: "Invalid 2xx JSON response (possible captive portal)", retryAfterSec: nil)
            }
            
            let serverMessage = Self.extractErrorMessage(from: data) ?? "HTTP \(statusCode)"
            
            switch statusCode {
            case 401, 403:
                return .configurationPaused(reason: "Resend error (\(statusCode)): \(serverMessage)")
            case 408, 425, 429, 500...599:
                let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
                let parsedRetryAfter = retryAfterHeader.flatMap { TimeInterval($0) }
                return .transientFailure(reason: "Server transient error (\(statusCode)): \(serverMessage)", retryAfterSec: parsedRetryAfter)
            case 400, 422:
                return .permanentRecipientFailure(reason: "Recipient rejected (\(statusCode)): \(serverMessage)")
            default:
                return .transientFailure(reason: "Unexpected HTTP \(statusCode): \(serverMessage)", retryAfterSec: nil)
            }
        } catch let urlError as URLError {
            return .transientFailure(reason: "Network error (\(urlError.code.rawValue)): \(urlError.localizedDescription)", retryAfterSec: nil)
        } catch {
            return .transientFailure(reason: "Transport error: \(error.localizedDescription)", retryAfterSec: nil)
        }
    }
    
    nonisolated private static func extractErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let errorStr = json["error"] as? String, !errorStr.isEmpty {
                return errorStr
            }
        }
        if let raw = String(data: data.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           !raw.lowercased().contains("<html") {
            return raw
        }
        return nil
    }
}

// MARK: - Production Native Gmail / TLS SMTP Transport (smtp.gmail.com:465)

final class GmailSMTPTransport: EmailTransport, @unchecked Sendable {
    private nonisolated let host: String
    private nonisolated let port: UInt16
    private nonisolated let timeoutSec: TimeInterval
    
    nonisolated init(
        host: String = "smtp.gmail.com",
        port: UInt16 = 465,
        timeoutSec: TimeInterval = 35.0
    ) {
        self.host = host
        self.port = port
        self.timeoutSec = timeoutSec
    }
    
    /// Extracts the bare email address and formatted From header from strings like `"Photobooth <joshal7@gmail.com>"` or `"joshal7@gmail.com"`.
    nonisolated static func parseSenderAddress(_ rawFrom: String) -> (envelopeEmail: String, formattedHeader: String) {
        let trimmed = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openIdx = trimmed.firstIndex(of: "<"),
           let closeIdx = trimmed.firstIndex(of: ">"),
           openIdx < closeIdx {
            let email = String(trimmed[trimmed.index(after: openIdx)..<closeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (email, trimmed)
        }
        if trimmed.contains("@") {
            return (trimmed, "Photobooth <\(trimmed)>")
        }
        return (trimmed, trimmed)
    }
    
    /// Builds an RFC 5322 / MIME `multipart/mixed` message with 76-character Base64 chunks.
    nonisolated static func buildMIMEMessage(
        _ request: EmailDeliveryRequest,
        envelopeSender: String,
        formattedFromHeader: String
    ) -> Data {
        let mixedBoundary = "Boundary_Mixed_\(request.jobID.uuidString.replacingOccurrences(of: "-", with: ""))"
        let altBoundary = "Boundary_Alt_\(request.jobID.uuidString.replacingOccurrences(of: "-", with: ""))"
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let rfc2822Date = dateFormatter.string(from: Date())
        
        let subjectB64 = Data(request.subject.utf8).base64EncodedString()
        let plainB64 = Data(request.textBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let htmlB64 = Data(request.htmlBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        
        var out = Data()
        func appendLine(_ line: String) {
            out.append(contentsOf: line.utf8)
            out.append(contentsOf: [0x0D, 0x0A]) // \r\n
        }
        
        appendLine("From: \(formattedFromHeader)")
        appendLine("To: <\(request.to)>")
        appendLine("Subject: =?UTF-8?B?\(subjectB64)?=")
        appendLine("Message-ID: <\(request.idempotencyKey)@photobooth.joshal.com>")
        appendLine("Date: \(rfc2822Date)")
        appendLine("MIME-Version: 1.0")
        appendLine("Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"")
        appendLine("")
        appendLine("--\(mixedBoundary)")
        appendLine("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"")
        appendLine("")
        appendLine("--\(altBoundary)")
        appendLine("Content-Type: text/plain; charset=\"UTF-8\"")
        appendLine("Content-Transfer-Encoding: base64")
        appendLine("")
        out.append(contentsOf: plainB64.utf8)
        out.append(contentsOf: [0x0D, 0x0A])
        appendLine("--\(altBoundary)")
        appendLine("Content-Type: text/html; charset=\"UTF-8\"")
        appendLine("Content-Transfer-Encoding: base64")
        appendLine("")
        out.append(contentsOf: htmlB64.utf8)
        out.append(contentsOf: [0x0D, 0x0A])
        appendLine("--\(altBoundary)--")
        
        for att in request.attachments {
            let safeName = att.filename.replacingOccurrences(of: "\"", with: "")
            appendLine("--\(mixedBoundary)")
            appendLine("Content-Type: \(att.contentType); name=\"\(safeName)\"")
            appendLine("Content-Disposition: attachment; filename=\"\(safeName)\"")
            appendLine("Content-Transfer-Encoding: base64")
            appendLine("")
            let b64 = att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out.append(contentsOf: b64.utf8)
            out.append(contentsOf: [0x0D, 0x0A])
        }
        
        appendLine("--\(mixedBoundary)--")
        appendLine(".")
        return out
    }
    
    nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome {
        let cleanedPassword = request.apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !cleanedPassword.isEmpty else {
            return .configurationPaused(
                reason: "Email credentials not configured — open Settings > Sharing to enter your 16-character Gmail App Password or Resend API Key"
            )
        }
        
        let (envelopeSender, formattedFrom) = Self.parseSenderAddress(request.from)
        guard EmailQueueService.isValidEmail(envelopeSender) else {
            return .configurationPaused(
                reason: "Invalid Sender Address '\(request.from)' — set Sender Address in Settings to your @gmail.com address"
            )
        }
        
        let mimePayload = autoreleasepool {
            Self.buildMIMEMessage(request, envelopeSender: envelopeSender, formattedFromHeader: formattedFrom)
        }
        
        let session = SMTPTLSSession(host: host, port: port, timeoutSec: timeoutSec)
        defer { session.cancel() }
        
        do {
            try await session.connect()
            
            // 1. Read 220 Greeting
            let greeting = try await session.readResponse()
            guard greeting.code == 220 else {
                return Self.classifySMTPError(step: "Greeting", response: greeting)
            }
            
            // 2. EHLO
            try await session.sendLine("EHLO photobooth.local")
            let ehloResp = try await session.readResponse()
            guard (200...299).contains(ehloResp.code) else {
                return Self.classifySMTPError(step: "EHLO", response: ehloResp)
            }
            
            // 3. AUTH PLAIN \0username\0password
            var authBytes = Data([0x00])
            authBytes.append(contentsOf: envelopeSender.utf8)
            authBytes.append(0x00)
            authBytes.append(contentsOf: cleanedPassword.utf8)
            let authPlainB64 = authBytes.base64EncodedString()
            
            try await session.sendLine("AUTH PLAIN \(authPlainB64)")
            let authResp = try await session.readResponse()
            guard authResp.code == 235 else {
                if authResp.code == 535 || authResp.code == 534 || authResp.code == 530 {
                    return .configurationPaused(
                        reason: "Gmail login rejected (\(authResp.code)): Ensure 'Sender Address' is your @gmail.com address and 'App Password / API Key' is a 16-char Google App Password (myaccount.google.com/apppasswords)."
                    )
                }
                return Self.classifySMTPError(step: "AUTH", response: authResp)
            }
            
            // 4. MAIL FROM
            try await session.sendLine("MAIL FROM:<\(envelopeSender)>")
            let mailResp = try await session.readResponse()
            guard (200...299).contains(mailResp.code) else {
                return Self.classifySMTPError(step: "MAIL FROM", response: mailResp)
            }
            
            // 5. RCPT TO
            try await session.sendLine("RCPT TO:<\(request.to)>")
            let rcptResp = try await session.readResponse()
            guard (200...299).contains(rcptResp.code) else {
                if rcptResp.code == 550 || rcptResp.code == 553 || rcptResp.code == 501 {
                    return .permanentRecipientFailure(reason: "Recipient rejected (\(rcptResp.code)): \(rcptResp.message)")
                }
                return Self.classifySMTPError(step: "RCPT TO", response: rcptResp)
            }
            
            // 6. DATA command
            try await session.sendLine("DATA")
            let dataResp = try await session.readResponse()
            guard dataResp.code == 354 else {
                return Self.classifySMTPError(step: "DATA", response: dataResp)
            }
            
            // 7. Stream MIME body + trailing .\r\n
            try await session.sendRawData(mimePayload)
            let finalResp = try await session.readResponse()
            guard (200...299).contains(finalResp.code) else {
                return Self.classifySMTPError(step: "MIME DATA", response: finalResp)
            }
            
            // 8. Best-effort QUIT
            try? await session.sendLine("QUIT")
            return .sent(providerMessageID: "smtp_\(request.jobID.uuidString)")
        } catch {
            return .transientFailure(reason: "SMTP network error: \(error.localizedDescription)", retryAfterSec: nil)
        }
    }
    
    nonisolated private static func classifySMTPError(step: String, response: (code: Int, message: String)) -> EmailSendOutcome {
        if response.code == 535 || response.code == 534 || response.code == 530 {
            return .configurationPaused(reason: "SMTP auth error (\(response.code)): \(response.message)")
        }
        if (400...499).contains(response.code) {
            return .transientFailure(reason: "SMTP \(step) transient (\(response.code)): \(response.message)", retryAfterSec: nil)
        }
        return .transientFailure(reason: "SMTP \(step) error (\(response.code)): \(response.message)", retryAfterSec: nil)
    }
}

/// Thread-safe async TLS socket wrapper around `NWConnection` for SMTP over port 465.
private nonisolated final class SMTPTLSSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.photobooth2.smtpTLSSession", qos: .utility)
    private let timeoutSec: TimeInterval
    private var readBuffer = Data()
    
    init(host: String, port: UInt16, timeoutSec: TimeInterval) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .imaps
        self.connection = NWConnection(host: nwHost, port: nwPort, using: .tls)
        self.timeoutSec = timeoutSec
    }
    
    func cancel() {
        connection.cancel()
    }
    
    private nonisolated final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }
    
    func connect() async throws {
        try await withTimeout(seconds: timeoutSec) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let gate = OneShotGate()
                
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if gate.tryAcquire() {
                            cont.resume()
                        }
                    case .failed(let err):
                        if gate.tryAcquire() {
                            cont.resume(throwing: err)
                        }
                    case .cancelled:
                        if gate.tryAcquire() {
                            cont.resume(throwing: URLError(.cancelled))
                        }
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }
    
    func sendLine(_ line: String) async throws {
        var data = Data(line.utf8)
        data.append(contentsOf: [0x0D, 0x0A])
        try await sendRawData(data)
    }
    
    func sendRawData(_ data: Data) async throws {
        try await withTimeout(seconds: timeoutSec) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }
    
    /// Reads a complete single-line or multi-line SMTP response (`XYZ-...` followed by `XYZ ...`).
    func readResponse() async throws -> (code: Int, message: String) {
        return try await withTimeout(seconds: timeoutSec) {
            var collectedLines: [String] = []
            while true {
                if let line = self.popNextLineFromBuffer() {
                    collectedLines.append(line)
                    if line.count >= 3,
                       let code = Int(line.prefix(3)) {
                        let fourthIndex = line.index(line.startIndex, offsetBy: 3)
                        if line.count == 3 || line[fourthIndex] == " " {
                            return (code, collectedLines.joined(separator: " | "))
                        }
                    }
                    continue
                }
                let chunk = try await self.receiveChunk()
                if chunk.isEmpty {
                    throw URLError(.networkConnectionLost)
                }
                self.readBuffer.append(chunk)
            }
        }
    }
    
    private func popNextLineFromBuffer() -> String? {
        guard let range = readBuffer.range(of: Data([0x0D, 0x0A])) ?? readBuffer.range(of: Data([0x0A])) else {
            return nil
        }
        let lineData = readBuffer.subdata(in: 0..<range.lowerBound)
        readBuffer.removeSubrange(0..<range.upperBound)
        return String(data: lineData, encoding: .utf8) ?? ""
    }
    
    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }
    
    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return first
        }
    }
}

/// Automatically routes `re_...` API keys to `ResendEmailTransport` and Gmail App Passwords to `GmailSMTPTransport`.
final class CompositeEmailTransport: EmailTransport, @unchecked Sendable {
    private nonisolated let resendTransport: ResendEmailTransport
    private nonisolated let gmailTransport: GmailSMTPTransport
    
    nonisolated init(
        resendTransport: ResendEmailTransport = ResendEmailTransport(),
        gmailTransport: GmailSMTPTransport = GmailSMTPTransport()
    ) {
        self.resendTransport = resendTransport
        self.gmailTransport = gmailTransport
    }
    
    nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome {
        let trimmedKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .configurationPaused(
                reason: "Email Sender not configured — open Settings > Sharing to enter your 16-char Gmail App Password or Resend API Key"
            )
        }
        if trimmedKey.lowercased().hasPrefix("re_") {
            return await resendTransport.sendEmail(request)
        } else {
            return await gmailTransport.sendEmail(request)
        }
    }
}

// MARK: - EmailQueueService

final class EmailQueueService: ObservableObject, @unchecked Sendable {
    nonisolated static let shared = EmailQueueService()
    
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var sendingCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var totalSentCount: Int = 0
    @Published private(set) var isNetworkConnected: Bool = false
    @Published private(set) var isConfigured: Bool = false
    @Published private(set) var lastStatusMessage: String? = nil
    @Published private(set) var queueItems: [EmailQueueItem] = []
    
    private nonisolated final class Storage: @unchecked Sendable {
        let lock = NSLock()
        let rootDirectoryURL: URL
        let manifestFileURL: URL
        var document: EmailQueueManifestDocument
        var isNetworkConnected: Bool
        var hasReceivedInitialNetworkReading: Bool = false
        var isFlushing: Bool = false
        var needsFollowUpFlush: Bool = false
        var flushWaiters: [CheckedContinuation<Void, Never>] = []
        var apiKeyOverride: String?
        var fromAddressOverride: String?
        var subjectOverride: String?
        var networkDebounceSec: TimeInterval
        var baseBackoffSec: TimeInterval
        var maxBackoffSec: TimeInterval
        var debounceTask: Task<Void, Never>?
        var retryWakeupTask: Task<Void, Never>?
        
        init(
            rootDirectoryURL: URL,
            manifestFileURL: URL,
            initialDocument: EmailQueueManifestDocument,
            initialNetworkConnected: Bool,
            networkDebounceSec: TimeInterval,
            baseBackoffSec: TimeInterval,
            maxBackoffSec: TimeInterval
        ) {
            self.rootDirectoryURL = rootDirectoryURL
            self.manifestFileURL = manifestFileURL
            self.document = initialDocument
            self.isNetworkConnected = initialNetworkConnected
            self.networkDebounceSec = networkDebounceSec
            self.baseBackoffSec = baseBackoffSec
            self.maxBackoffSec = maxBackoffSec
        }
    }
    
    private nonisolated let storage: Storage
    private nonisolated let transport: EmailTransport
    private nonisolated let pathMonitor: NWPathMonitor?
    private nonisolated let monitorQueue: DispatchQueue?
    
    nonisolated static var defaultQueueRootDirectory: URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseDir.appendingPathComponent("PhotoboothEmailQueue", isDirectory: true)
    }
    
    nonisolated init(
        customDirectoryURL: URL? = nil,
        transport: EmailTransport = CompositeEmailTransport(),
        useSystemNetworkMonitor: Bool = true,
        initialNetworkConnected: Bool = false,
        networkDebounceSec: TimeInterval = 2.0,
        baseBackoffSec: TimeInterval = 5.0,
        maxBackoffSec: TimeInterval = 300.0,
        apiKeyOverride: String? = nil,
        fromAddressOverride: String? = nil,
        subjectOverride: String? = nil
    ) {
        let rootDir = customDirectoryURL ?? Self.defaultQueueRootDirectory
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let manifestURL = rootDir.appendingPathComponent(EmailQueueManifestDocument.defaultFilename)
        
        var loadedDoc: EmailQueueManifestDocument
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? Self.makeJSONDecoder().decode(EmailQueueManifestDocument.self, from: data) {
            loadedDoc = decoded
        } else {
            loadedDoc = EmailQueueManifestDocument()
        }
        
        // Crash / Reboot Recovery: reset any job left in `.sending` back to `.pending`
        // so interrupted uploads automatically resume.
        var didRecoverInterrupted = false
        let now = Date()
        for i in loadedDoc.items.indices {
            if loadedDoc.items[i].status == .sending {
                loadedDoc.items[i].status = .pending
                loadedDoc.items[i].nextAttemptAt = now
                didRecoverInterrupted = true
            }
        }
        
        self.transport = transport
        self.storage = Storage(
            rootDirectoryURL: rootDir,
            manifestFileURL: manifestURL,
            initialDocument: loadedDoc,
            initialNetworkConnected: initialNetworkConnected,
            networkDebounceSec: networkDebounceSec,
            baseBackoffSec: baseBackoffSec,
            maxBackoffSec: maxBackoffSec
        )
        self.storage.apiKeyOverride = apiKeyOverride
        self.storage.fromAddressOverride = fromAddressOverride
        self.storage.subjectOverride = subjectOverride
        
        if didRecoverInterrupted {
            Self.saveDocumentLocked(storage.document, to: manifestURL)
        }
        
        if useSystemNetworkMonitor {
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.photobooth2.emailQueueNetworkMonitor", qos: .utility)
            self.pathMonitor = monitor
            self.monitorQueue = queue
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handleNetworkStatusChange(isConnected: path.status == .satisfied, isSystemMonitorCallback: true)
            }
            monitor.start(queue: queue)
        } else {
            self.pathMonitor = nil
            self.monitorQueue = nil
        }
        
        publishStateSnapshot()
        
        if initialNetworkConnected {
            triggerBackgroundFlush(ignoreBackoff: false)
        }
    }
    
    deinit {
        pathMonitor?.cancel()
        storage.lock.lock()
        let debounce = storage.debounceTask
        let wakeup = storage.retryWakeupTask
        storage.lock.unlock()
        debounce?.cancel()
        wakeup?.cancel()
    }
    
    // MARK: - Static Formatting, Validation & 2MP Normalization Helpers
    
    nonisolated static func isValidEmail(_ rawEmail: String) -> Bool {
        let trimmed = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.count <= 254, !trimmed.contains(" ") else {
            return false
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, domain.count >= 3 else { return false }
        guard !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        let domainLabels = domain.split(separator: ".")
        guard domainLabels.count >= 2, let tld = domainLabels.last, tld.count >= 2 else {
            return false
        }
        return true
    }
    
    nonisolated static func normalizeGalleryURL(_ rawURLString: String) -> String {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let currentYear = Calendar.current.component(.year, from: Date())
            return "https://www.joshal.com/\(currentYear)"
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }
    
    /// Ensures any oversized JPEG attachment (e.g. 12MP `4032x2688` from iPad Camera Mode) is downscaled
    /// to standard 2MP (`1620x1080`) at `0.85` JPEG quality before sending, while leaving already-2MP Sony JPEGs untouched.
    nonisolated static func normalizeJPEGAttachmentTo2MP(
        _ data: Data,
        maxPixelDimension: Int = 1620,
        compressionQuality: Double = 0.85
    ) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return data
        }
        guard max(width, height) > maxPixelDimension else {
            return data
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        guard let downscaledCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return data
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return data
        }
        let encodeProps: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(dest, downscaledCG, encodeProps as CFDictionary)
        guard CGImageDestinationFinalize(dest), mutableData.length > 0 else {
            return data
        }
        return mutableData as Data
    }
    
    /// Normalizes animated GIF attachments for email delivery (`960x640` at 3:2 landscape,
    /// preserving frame delays and infinite loop `LoopCount = 0`).
    /// This keeps the GIF within Gmail iOS's mobile viewer dimension threshold (`< 1000px` wide)
    /// while preserving inline email animation, Google Photos upload, and Mac download.
    nonisolated static func normalizeGIFAttachmentForEmail(
        _ data: Data,
        maxPixelDimension: Int = 960
    ) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1,
              let firstProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let srcWidth = firstProps[kCGImagePropertyPixelWidth] as? Int,
              let srcHeight = firstProps[kCGImagePropertyPixelHeight] as? Int,
              srcWidth > 0, srcHeight > 0 else {
            return data
        }
        
        let maxSrcDim = max(srcWidth, srcHeight)
        if maxSrcDim <= maxPixelDimension {
            return data
        }
        
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            return data
        }
        
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(dest, fileProperties as CFDictionary)
        
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension as NSNumber
        ]
        
        var encodedFrames = 0
        for index in 0..<frameCount {
            guard let scaledCG = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary) else {
                continue
            }
            
            var delayTime: Double = 0.5
            if let frameProps = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gifDict = frameProps[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let unclamped = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0.01 {
                    delayTime = unclamped
                } else if let clamped = gifDict[kCGImagePropertyGIFDelayTime] as? Double, clamped > 0.01 {
                    delayTime = clamped
                }
            }
            
            let frameProperties: [String: Any] = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFDelayTime as String: delayTime
                ]
            ]
            CGImageDestinationAddImage(dest, scaledCG, frameProperties as CFDictionary)
            encodedFrames += 1
        }
        
        guard encodedFrames > 1, CGImageDestinationFinalize(dest), mutableData.length > 0 else {
            return data
        }
        return mutableData as Data
    }
    
    /// Returns the descriptive sentence matching the media captured in the session:
    /// - Photos: "Your photos from your session are attached to this email."
    /// - GIF: "Your gif from your session are attached to this email."
    nonisolated static func sessionAttachmentDescription(for mediaOrFilenames: [String]) -> String {
        let lower = mediaOrFilenames.map { $0.lowercased() }
        let hasGIF = lower.contains { $0.hasSuffix(".gif") }
        let hasPhotos = lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        
        if hasGIF && !hasPhotos {
            return "Your gif from your session are attached to this email."
        } else {
            return "Your photos from your session are attached to this email."
        }
    }

    /// Builds the HTML email body containing the required hyperlinked gallery footer at the bottom.
    nonisolated static func buildEmailHTML(galleryURLString: String, mediaOrFilenames: [String] = []) -> String {
        let normalizedURL = normalizeGalleryURL(galleryURLString)
        let escapedURL = normalizedURL
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        
        let desc = sessionAttachmentDescription(for: mediaOrFilenames)
        let escapedDesc = desc
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        
        let lower = mediaOrFilenames.map { $0.lowercased() }
        let hasGIF = lower.contains { $0.hasSuffix(".gif") }
        let hasPhotos = lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        let footerNoun = (hasGIF && !hasPhotos) ? "gifs" : "photos"
        
        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="UTF-8"></head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #222222; line-height: 1.5; padding: 16px;">
          <p>Thanks for visiting the photobooth! \(escapedDesc)</p>
          <hr style="border: none; border-top: 1px solid #e0e0e0; margin: 24px 0;" />
          <p style="font-size: 14px; color: #444444;">All full resolution \(footerNoun) can be downloaded <a href="\(escapedURL)">here</a> a day or two after the event.</p>
        </body>
        </html>
        """
    }
    
    nonisolated static func buildEmailPlainText(galleryURLString: String, mediaOrFilenames: [String] = []) -> String {
        let normalizedURL = normalizeGalleryURL(galleryURLString)
        let desc = sessionAttachmentDescription(for: mediaOrFilenames)
        let lower = mediaOrFilenames.map { $0.lowercased() }
        let hasGIF = lower.contains { $0.hasSuffix(".gif") }
        let hasPhotos = lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        let footerNoun = (hasGIF && !hasPhotos) ? "gifs" : "photos"
        
        return """
        Thanks for visiting the photobooth! \(desc)

        All full resolution \(footerNoun) can be downloaded here (\(normalizedURL)) a day or two after the event.
        """
    }
    
    /// Generates clear, unambiguous confirmation copy distinguishing online vs. offline iPad status (and unconfigured credentials).
    nonisolated static func confirmationMessage(
        forEmail email: String,
        isOnline: Bool,
        isConfigured: Bool = true,
        mediaOrFilenames: [String] = []
    ) -> EmailConfirmationCopy {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = mediaOrFilenames.map { $0.lowercased() }
        let hasGIF = lower.contains { $0.hasSuffix(".gif") }
        let hasPhotos = lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        
        let mediaTitleNoun: String
        let mediaSubtitleNoun: String
        if hasGIF && !hasPhotos {
            mediaTitleNoun = "GIF"
            mediaSubtitleNoun = "GIF is"
        } else {
            mediaTitleNoun = "Photos"
            mediaSubtitleNoun = "photos are"
        }

        if !isConfigured {
            return EmailConfirmationCopy(
                title: "Saved to iPad Queue!",
                subtitle: "Queued for \(cleanEmail). Open Settings (⚙️) > Sharing and enter your Gmail App Password or Resend API Key to send queued emails.",
                isOnline: isOnline,
                isConfigured: false
            )
        } else if isOnline {
            return EmailConfirmationCopy(
                title: "Sending Your \(mediaTitleNoun)!",
                subtitle: "Your \(mediaSubtitleNoun) being emailed to \(cleanEmail) in the background right now.",
                isOnline: true,
                isConfigured: true
            )
        } else {
            return EmailConfirmationCopy(
                title: "Saved for Wi-Fi Delivery!",
                subtitle: "The iPad is currently offline. You will receive your email at \(cleanEmail) shortly after the iPad connects to Wi-Fi.",
                isOnline: false,
                isConfigured: true
            )
        }
    }
    
    /// Returns the display duration in nanoseconds for the post-email confirmation screen before returning to idle:
    /// - Online ("Sending Your Photos/GIF!"): 1.5s (`1_500_000_000` ns)
    /// - Offline ("Saved for Wi-Fi Delivery!"): 2.5s (`2_500_000_000` ns, +1 second so guests can read the Wi-Fi details)
    /// - Unconfigured credentials: 3.5s (`3_500_000_000` ns)
    nonisolated static func postSubmitDismissDurationNanoseconds(
        isOnline: Bool,
        isConfigured: Bool = true
    ) -> UInt64 {
        if !isConfigured {
            return 3_500_000_000
        }
        return isOnline ? 1_500_000_000 : 2_500_000_000
    }
    
    // MARK: - Enqueue (Zero Main-Thread Delay via APFS Hard-Link)
    
    /// Synchronously hard-links (or copies) session media from `/tmp` into `Application Support/PhotoboothEmailQueue/<id>/`,
    /// persists the queue manifest atomically, and kicks off asynchronous background delivery.
    @discardableResult
    nonisolated func enqueue(
        recipientEmail: String,
        mediaPaths: [String],
        galleryURLString: String,
        customSubject: String? = nil
    ) -> EmailQueueItem? {
        let trimmedEmail = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(trimmedEmail) else { return nil }
        
        let fm = FileManager.default
        let jobID = UUID()
        let jobDir = storage.rootDirectoryURL.appendingPathComponent(jobID.uuidString, isDirectory: true)
        
        do {
            try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        
        var savedFilenames: [String] = []
        var photoIndex = 1
        var gifIndex = 1
        
        for rawPath in mediaPaths {
            let sourceURL: URL
            if rawPath.hasPrefix("file://"), let parsed = URL(string: rawPath) {
                sourceURL = URL(fileURLWithPath: parsed.path)
            } else {
                sourceURL = URL(fileURLWithPath: rawPath)
            }
            
            guard fm.fileExists(atPath: sourceURL.path) else { continue }
            
            let ext = sourceURL.pathExtension.lowercased()
            let cleanFilename: String
            if ext == "gif" {
                cleanFilename = gifIndex == 1 ? "photobooth_animation.gif" : "photobooth_animation_\(gifIndex).gif"
                gifIndex += 1
            } else {
                let effectiveExt = ext.isEmpty ? "jpg" : ext
                cleanFilename = "photobooth_photo_\(photoIndex).\(effectiveExt)"
                photoIndex += 1
            }
            
            let destURL = jobDir.appendingPathComponent(cleanFilename)
            // Fast path: APFS hard-link (O(1) metadata operation, < 0.2ms, 0 extra bytes while /tmp lives,
            // and survives after StateMachine deletes the /tmp file).
            do {
                try fm.linkItem(at: sourceURL, to: destURL)
                savedFilenames.append(cleanFilename)
            } catch {
                // Fallback for cross-volume paths: regular file copy
                try? fm.removeItem(at: destURL)
                if (try? fm.copyItem(at: sourceURL, to: destURL)) != nil {
                    savedFilenames.append(cleanFilename)
                }
            }
        }
        
        guard !savedFilenames.isEmpty else {
            try? fm.removeItem(at: jobDir)
            return nil
        }
        
        let normalizedGalleryURL = Self.normalizeGalleryURL(galleryURLString)
        let resolvedSubject = customSubject ?? resolveSubject(for: savedFilenames)
        let now = Date()
        
        let newItem = EmailQueueItem(
            id: jobID,
            recipientEmail: trimmedEmail,
            galleryURLString: normalizedGalleryURL,
            subject: resolvedSubject,
            attachmentFilenames: savedFilenames,
            createdAt: now,
            status: .pending,
            attemptCount: 0,
            nextAttemptAt: now,
            lastError: nil
        )
        
        storage.lock.lock()
        storage.document.items.append(newItem)
        Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
        let isOnline = storage.isNetworkConnected
        storage.lock.unlock()
        
        let hasCredentials = checkHasConfiguredCredentials()
        publishStateSnapshot(
            statusMessage: !hasCredentials
                ? "Queued email to \(trimmedEmail) — enter Gmail App Password or Resend API Key in Settings to send"
                : (isOnline
                    ? "Queued email to \(trimmedEmail) — sending in background..."
                    : "Queued email to \(trimmedEmail) — waiting for Wi-Fi connection")
        )
        
        if isOnline {
            triggerBackgroundFlush(ignoreBackoff: false)
        }
        
        return newItem
    }
    
    // MARK: - Network Connectivity & Spotty Wi-Fi Handling
    
    nonisolated func setSimulatedNetworkConnected(_ connected: Bool) {
        handleNetworkStatusChange(isConnected: connected, isSystemMonitorCallback: false)
    }
    
    nonisolated private func handleNetworkStatusChange(isConnected: Bool, isSystemMonitorCallback: Bool) {
        storage.lock.lock()
        let previous = storage.isNetworkConnected
        let isInitialReading = isSystemMonitorCallback && !storage.hasReceivedInitialNetworkReading
        storage.hasReceivedInitialNetworkReading = true
        storage.isNetworkConnected = isConnected
        storage.debounceTask?.cancel()
        storage.debounceTask = nil
        
        let debounceSec = storage.networkDebounceSec
        let hasPending = storage.document.items.contains { $0.status == .pending }
        storage.lock.unlock()
        
        publishStateSnapshot(
            statusMessage: isConnected
                ? (hasPending ? "Wi-Fi connected — preparing to send queued emails..." : "Online")
                : (hasPending ? "Offline — queued emails will send when iPad connects to Wi-Fi" : "Offline")
        )
        
        if isConnected {
            if debounceSec <= 0 || isInitialReading {
                triggerBackgroundFlush(ignoreBackoff: false)
            } else {
                let task = Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(debounceSec * 1_000_000_000))
                    guard let self = self, !Task.isCancelled else { return }
                    self.triggerBackgroundFlush(ignoreBackoff: !previous)
                }
                storage.lock.lock()
                storage.debounceTask = task
                storage.lock.unlock()
            }
        } else {
            storage.lock.lock()
            storage.retryWakeupTask?.cancel()
            storage.retryWakeupTask = nil
            storage.lock.unlock()
        }
    }
    
    // MARK: - Serialized Background Queue Flush & Exponential Backoff
    
    nonisolated func notifyConfigurationUpdated() {
        publishStateSnapshot()
        storage.lock.lock()
        let isOnline = storage.isNetworkConnected
        let hasPending = storage.document.items.contains { $0.status == .pending }
        storage.lock.unlock()
        if isOnline && hasPending {
            triggerBackgroundFlush(ignoreBackoff: true)
        }
    }
    
    nonisolated func triggerBackgroundFlush(ignoreBackoff: Bool = false) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.flushQueue(ignoreBackoff: ignoreBackoff)
        }
    }
    
    nonisolated func flushQueue(ignoreBackoff: Bool = false) async {
        let shouldWaitForActiveFlush: Bool = storage.lock.withLock {
            if ignoreBackoff {
                let now = Date()
                for idx in storage.document.items.indices where storage.document.items[idx].status == .pending {
                    storage.document.items[idx].nextAttemptAt = now
                }
            }
            if storage.isFlushing {
                storage.needsFollowUpFlush = true
                return true
            }
            storage.isFlushing = true
            storage.needsFollowUpFlush = false
            storage.retryWakeupTask?.cancel()
            storage.retryWakeupTask = nil
            return false
        }
        
        if shouldWaitForActiveFlush {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeImmediately: Bool = storage.lock.withLock {
                    if storage.isFlushing {
                        storage.flushWaiters.append(continuation)
                        return false
                    }
                    return true
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
            return
        }
        
        defer {
            let waiters: [CheckedContinuation<Void, Never>] = storage.lock.withLock {
                storage.isFlushing = false
                storage.needsFollowUpFlush = false
                let queuedWaiters = storage.flushWaiters
                storage.flushWaiters.removeAll()
                return queuedWaiters
            }
            
            publishStateSnapshot()
            scheduleNextBackoffWakeupIfNeeded()
            
            for waiter in waiters {
                waiter.resume()
            }
        }
        
        var didPauseForConfiguration = false
        
        repeat {
            storage.lock.withLock {
                storage.needsFollowUpFlush = false
            }
            
            while true {
                if Task.isCancelled { break }
                
                let nextCandidate: EmailQueueItem? = storage.lock.withLock {
                    guard storage.isNetworkConnected else {
                        return nil
                    }
                    let now = Date()
                    guard let itemIndex = storage.document.items.indices.first(where: { idx in
                        let item = storage.document.items[idx]
                        return item.status == .pending && item.nextAttemptAt <= now
                    }) else {
                        return nil
                    }
                    storage.document.items[itemIndex].status = .sending
                    let currentItem = storage.document.items[itemIndex]
                    Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                    return currentItem
                }
                
                guard let currentItem = nextCandidate else {
                    break
                }
                
                publishStateSnapshot(statusMessage: "Sending email to \(currentItem.recipientEmail)...")
                
                let jobDir = storage.rootDirectoryURL.appendingPathComponent(currentItem.id.uuidString, isDirectory: true)
                let attachments: [EmailAttachmentPayload] = autoreleasepool {
                    var loaded: [EmailAttachmentPayload] = []
                    for fname in currentItem.attachmentFilenames {
                        let fileURL = jobDir.appendingPathComponent(fname)
                        if let rawData = try? Data(contentsOf: fileURL), !rawData.isEmpty {
                            let isGIF = fname.lowercased().hasSuffix(".gif")
                            let contentType = isGIF ? "image/gif" : "image/jpeg"
                            let finalData = isGIF
                                ? Self.normalizeGIFAttachmentForEmail(rawData)
                                : Self.normalizeJPEGAttachmentTo2MP(rawData)
                            loaded.append(EmailAttachmentPayload(filename: fname, contentType: contentType, data: finalData))
                        }
                    }
                    return loaded
                }
                
                // If attachment files were externally deleted/missing, clean up the orphaned record so it cannot block the queue
                if attachments.isEmpty {
                    storage.lock.withLock {
                        storage.document.items.removeAll { $0.id == currentItem.id }
                        Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                    }
                    try? FileManager.default.removeItem(at: jobDir)
                    publishStateSnapshot(statusMessage: "Removed orphaned email job with missing attachments")
                    continue
                }
                
                let deliveryRequest = EmailDeliveryRequest(
                    jobID: currentItem.id,
                    idempotencyKey: currentItem.id.uuidString,
                    from: resolveFromAddress(),
                    to: currentItem.recipientEmail,
                    subject: currentItem.subject,
                    htmlBody: Self.buildEmailHTML(galleryURLString: currentItem.galleryURLString, mediaOrFilenames: currentItem.attachmentFilenames),
                    textBody: Self.buildEmailPlainText(galleryURLString: currentItem.galleryURLString, mediaOrFilenames: currentItem.attachmentFilenames),
                    attachments: attachments,
                    apiKey: resolveAPIKey()
                )
                
                let outcome = await transport.sendEmail(deliveryRequest)
                
                switch outcome {
                case .sent:
                    // 1. Delete job's local media folder immediately upon verified 2xx delivery
                    try? FileManager.default.removeItem(at: jobDir)
                    
                    // 2. Remove from pending manifest & increment sent counter atomically
                    storage.lock.withLock {
                        storage.document.items.removeAll { $0.id == currentItem.id }
                        storage.document.totalSentCount += 1
                        Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                    }
                    
                    publishStateSnapshot(statusMessage: "Sent email to \(currentItem.recipientEmail)")
                    
                case .transientFailure(let reason, let serverRetryAfter):
                    storage.lock.withLock {
                        if let idx = storage.document.items.firstIndex(where: { $0.id == currentItem.id }) {
                            let newAttempt = storage.document.items[idx].attemptCount + 1
                            storage.document.items[idx].attemptCount = newAttempt
                            storage.document.items[idx].status = .pending
                            storage.document.items[idx].lastError = reason
                            
                            let computedBackoff = min(
                                storage.maxBackoffSec,
                                storage.baseBackoffSec * pow(2.0, Double(max(0, newAttempt - 1)))
                            )
                            let delaySec = max(computedBackoff, serverRetryAfter ?? 0)
                            storage.document.items[idx].nextAttemptAt = Date().addingTimeInterval(delaySec)
                            Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                        }
                    }
                    
                    publishStateSnapshot(statusMessage: "Spotty connection — will retry \(currentItem.recipientEmail) automatically (\(reason))")
                    
                case .configurationPaused(let reason):
                    storage.lock.withLock {
                        if let idx = storage.document.items.firstIndex(where: { $0.id == currentItem.id }) {
                            storage.document.items[idx].status = .pending
                            storage.document.items[idx].lastError = reason
                            Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                        }
                    }
                    
                    publishStateSnapshot(statusMessage: reason)
                    didPauseForConfiguration = true
                    break
                    
                case .permanentRecipientFailure(let reason):
                    storage.lock.withLock {
                        if let idx = storage.document.items.firstIndex(where: { $0.id == currentItem.id }) {
                            storage.document.items[idx].attemptCount += 1
                            storage.document.items[idx].status = .failedPermanent
                            storage.document.items[idx].lastError = reason
                            Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
                        }
                    }
                    
                    publishStateSnapshot(statusMessage: "Failed delivery to \(currentItem.recipientEmail): \(reason)")
                }
                
                if didPauseForConfiguration {
                    break
                }
            }
            
            let shouldLoopAgain: Bool = storage.lock.withLock {
                !didPauseForConfiguration && storage.needsFollowUpFlush && storage.isNetworkConnected
            }
            if !shouldLoopAgain {
                break
            }
        } while true
    }
    
    nonisolated private func scheduleNextBackoffWakeupIfNeeded() {
        storage.lock.lock()
        storage.retryWakeupTask?.cancel()
        storage.retryWakeupTask = nil
        
        guard storage.isNetworkConnected else {
            storage.lock.unlock()
            return
        }
        
        let pendingDates = storage.document.items
            .filter { $0.status == .pending }
            .map(\.nextAttemptAt)
        guard let earliestNext = pendingDates.min() else {
            storage.lock.unlock()
            return
        }
        
        let waitSec = max(0.02, earliestNext.timeIntervalSinceNow)
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            await self.flushQueue(ignoreBackoff: false)
        }
        storage.retryWakeupTask = task
        storage.lock.unlock()
    }
    
    // MARK: - Queue Management, Diagnostics & Maintenance
    
    nonisolated func retryFailedAndPendingJobs() async {
        storage.lock.withLock {
            let now = Date()
            for idx in storage.document.items.indices {
                storage.document.items[idx].status = .pending
                storage.document.items[idx].nextAttemptAt = now
            }
            Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
        }
        
        publishStateSnapshot(statusMessage: "Retrying queued emails...")
        await flushQueue(ignoreBackoff: true)
    }
    
    /// Sends a live diagnostic test email to verify credentials and network connectivity from Settings.
    nonisolated func sendDiagnosticTestEmail(to recipientOverride: String? = nil, galleryURLString: String) async -> (success: Bool, message: String) {
        let fromAddr = resolveFromAddress()
        let (parsedSenderEmail, _) = GmailSMTPTransport.parseSenderAddress(fromAddr)
        let targetEmail = (recipientOverride?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? parsedSenderEmail
        
        guard Self.isValidEmail(targetEmail) else {
            let msg = "Enter a valid Sender Address (e.g. your @gmail.com address) in Settings first."
            publishStateSnapshot(statusMessage: msg)
            return (false, msg)
        }
        
        publishStateSnapshot(statusMessage: "Sending test email to \(targetEmail)...")
        let testID = UUID()
        let req = EmailDeliveryRequest(
            jobID: testID,
            idempotencyKey: testID.uuidString,
            from: fromAddr,
            to: targetEmail,
            subject: "Photobooth Test Email",
            htmlBody: Self.buildEmailHTML(galleryURLString: galleryURLString),
            textBody: Self.buildEmailPlainText(galleryURLString: galleryURLString),
            attachments: [],
            apiKey: resolveAPIKey()
        )
        
        let outcome = await transport.sendEmail(req)
        switch outcome {
        case .sent:
            let msg = "✅ Test email sent to \(targetEmail)!"
            publishStateSnapshot(statusMessage: msg)
            // Also flush any pending jobs now that credentials are verified
            await flushQueue(ignoreBackoff: true)
            return (true, msg)
        case .configurationPaused(let reason),
             .transientFailure(let reason, _),
             .permanentRecipientFailure(let reason):
            let msg = "❌ \(reason)"
            publishStateSnapshot(statusMessage: msg)
            return (false, msg)
        }
    }
    
    /// Purges permanently failed jobs older than `maxAgeDays` (default 7 days) and removes any unreferenced job folders.
    nonisolated func purgeExpiredFailedJobs(maxAgeDays: Int = 7) {
        let cutoff = Date().addingTimeInterval(-Double(max(1, maxAgeDays)) * 24 * 3600)
        var removedIDs: [UUID] = []
        
        storage.lock.lock()
        storage.document.items.removeAll { item in
            if item.status == .failedPermanent && item.createdAt < cutoff {
                removedIDs.append(item.id)
                return true
            }
            return false
        }
        if !removedIDs.isEmpty {
            Self.saveDocumentLocked(storage.document, to: storage.manifestFileURL)
        }
        let activeIDs = Set(storage.document.items.map { $0.id.uuidString })
        let rootDir = storage.rootDirectoryURL
        storage.lock.unlock()
        
        let fm = FileManager.default
        for id in removedIDs {
            try? fm.removeItem(at: rootDir.appendingPathComponent(id.uuidString, isDirectory: true))
        }
        
        // Clean up any orphaned subdirectories not referenced in the manifest
        if let contents = try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                if url.lastPathComponent == EmailQueueManifestDocument.defaultFilename { continue }
                if !activeIDs.contains(url.lastPathComponent) {
                    try? fm.removeItem(at: url)
                }
            }
        }
        
        if !removedIDs.isEmpty {
            publishStateSnapshot()
        }
    }
    
    nonisolated func currentItemsSnapshot() -> [EmailQueueItem] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.document.items
    }
    
    nonisolated func currentStatsSnapshot() -> (pending: Int, sending: Int, failed: Int, sent: Int, isOnline: Bool) {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let items = storage.document.items
        let pending = items.filter { $0.status == .pending }.count
        let sending = items.filter { $0.status == .sending }.count
        let failed = items.filter { $0.status == .failedPermanent }.count
        return (pending, sending, failed, storage.document.totalSentCount, storage.isNetworkConnected)
    }
    
    nonisolated func checkHasConfiguredCredentials() -> Bool {
        let key = resolveAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let (senderEmail, _) = GmailSMTPTransport.parseSenderAddress(resolveFromAddress())
        return !key.isEmpty && Self.isValidEmail(senderEmail)
    }
    
    // MARK: - Private Helpers
    
    nonisolated private func resolveAPIKey() -> String {
        storage.lock.lock()
        let override = storage.apiKeyOverride
        storage.lock.unlock()
        if let override = override { return override }
        return UserDefaults.standard.string(forKey: "emailAPIKey") ?? ""
    }
    
    nonisolated private func resolveFromAddress() -> String {
        storage.lock.lock()
        let override = storage.fromAddressOverride
        storage.lock.unlock()
        if let override = override { return override }
        return UserDefaults.standard.string(forKey: "emailFromAddress") ?? "Photobooth <joshal7@gmail.com>"
    }
    
    nonisolated private func resolveSubject(for mediaFilenames: [String] = []) -> String {
        storage.lock.lock()
        let override = storage.subjectOverride
        storage.lock.unlock()
        if let override = override { return override }
        let configured = UserDefaults.standard.string(forKey: "emailSubject") ?? "Your Photobooth Photos"
        
        // If subject has not been customized (or matches defaults), tailor specifically to Photos or GIF
        if configured == "Your Photobooth Photos" || configured == "Your Photobooth Photos!" || configured == "Your Photobooth Photos & GIF!" || configured.isEmpty {
            let lower = mediaFilenames.map { $0.lowercased() }
            let hasGIF = lower.contains { $0.hasSuffix(".gif") }
            let hasPhotos = lower.contains { $0.hasSuffix(".jpg") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
            if hasGIF && !hasPhotos {
                return "Your Photobooth GIF"
            } else {
                return "Your Photobooth Photos"
            }
        }
        return configured
    }
    
    nonisolated private func publishStateSnapshot(statusMessage: String? = nil) {
        storage.lock.lock()
        let items = storage.document.items
        let sent = storage.document.totalSentCount
        let online = storage.isNetworkConnected
        storage.lock.unlock()
        
        let configured = checkHasConfiguredCredentials()
        let pending = items.filter { $0.status == .pending }.count
        let sending = items.filter { $0.status == .sending }.count
        let failed = items.filter { $0.status == .failedPermanent }.count
        
        let applyOnMain = { @MainActor [weak self] in
            guard let self = self else { return }
            self.queueItems = items
            self.pendingCount = pending
            self.sendingCount = sending
            self.failedCount = failed
            self.totalSentCount = sent
            self.isNetworkConnected = online
            self.isConfigured = configured
            if let statusMessage = statusMessage {
                self.lastStatusMessage = statusMessage
            }
        }
        
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyOnMain() }
        } else {
            Task { @MainActor in applyOnMain() }
        }
    }
    
    nonisolated private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    
    nonisolated private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
    
    nonisolated private static func saveDocumentLocked(_ document: EmailQueueManifestDocument, to url: URL) {
        guard let data = try? makeJSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
