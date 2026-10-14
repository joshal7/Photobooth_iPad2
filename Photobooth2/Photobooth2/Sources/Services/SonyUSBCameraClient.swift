import Foundation
import Combine
import UIKit
import ImageCaptureCore

/// Abstraction over `ICCameraDevice.requestSendPTPCommand` to allow deterministic unit testing.
protocol PTPTransport: AnyObject, Sendable {
    nonisolated func sendPTPCommand(_ commandPacket: Data, outData: Data?) async throws -> (inData: Data, responsePacket: Data)
}

/// Serializes all USB PTP commands over the half-duplex bulk pipe and assigns sequential transaction IDs.
actor PTPCommandQueue {
    private var nextTransactionID: UInt32 = 1
    private var activeHighPriorityCount: Int = 0
    private var activeCaptureScopes: Int = 0
    
    var isBusyWithCaptureOrConfig: Bool {
        activeHighPriorityCount > 0 || activeCaptureScopes > 0
    }
    
    func beginCaptureScope() {
        activeCaptureScopes += 1
    }
    
    func endCaptureScope() {
        activeCaptureScopes = max(0, activeCaptureScopes - 1)
    }
    
    func execute(
        on transport: PTPTransport,
        opcode: SonyPTPOpcode,
        params: [UInt32] = [],
        outData: Data? = nil,
        highPriority: Bool = true
    ) async throws -> (inData: Data, responseCode: UInt16) {
        if highPriority {
            activeHighPriorityCount += 1
        }
        defer {
            if highPriority {
                activeHighPriorityCount = max(0, activeHighPriorityCount - 1)
            }
        }
        
        let txID = nextTransactionID
        nextTransactionID &+= 1
        
        let cmdPacket = SonyPTPPacket.buildCommand(opcode: opcode, transactionID: txID, params: params)
        let (inData, responsePacket) = try await transport.sendPTPCommand(cmdPacket, outData: outData)
        let responseCode = SonyPTPPacket.parseResponseCode(from: responsePacket) ?? SonyPTPResponseCode.ok.rawValue
        return (inData, responseCode)
    }
}

/// Bridges an `ICCameraDevice` to `PTPTransport`.
final class ICCameraPTPTransport: PTPTransport, @unchecked Sendable {
    nonisolated(unsafe) private weak var device: ICCameraDevice?
    
    nonisolated init(device: ICCameraDevice) {
        self.device = device
    }
    
    nonisolated func sendPTPCommand(_ commandPacket: Data, outData: Data?) async throws -> (inData: Data, responsePacket: Data) {
        guard let device = device, device.hasOpenSession else {
            throw CameraError.connectionFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            device.requestSendPTPCommand(commandPacket, outData: outData) { inData, responsePacket, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (inData, responsePacket))
                }
            }
        }
    }
}

class SonyUSBCameraClient: NSObject, CameraService, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private static let sonyUSBVendorID: Int = 0x054C
    private static let sonyProtocolVersion3: UInt32 = 0x012C // 3.00 for BIONZ XR (A7 IV / A7R V / A7V)
    
    @Published var isConnected: Bool = false
    var connectionStatus: AnyPublisher<Bool, Never> { $isConnected.eraseToAnyPublisher() }
    
    @Published var statusMessage: String? = nil
    
    private let _previewStream = PassthroughSubject<UIImage?, Never>()
    var previewStream: AnyPublisher<UIImage?, Never> { _previewStream.eraseToAnyPublisher() }
    
    private let commandQueue = PTPCommandQueue()
    private var deviceBrowser: ICDeviceBrowser?
    private var cameraDevice: ICCameraDevice?
    private var ptpTransport: PTPTransport?
    private var liveViewTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var wasLiveViewRunningBeforeSuspend: Bool = false
    private var sessionOpenContinuation: CheckedContinuation<Void, Error>?
    
    init(injectedTransport: PTPTransport? = nil) {
        self.ptpTransport = injectedTransport
        super.init()
        if injectedTransport == nil {
            setupDeviceBrowser()
        }
    }
    
    deinit {
        liveViewTask?.cancel()
        keepAliveTask?.cancel()
    }
    
    private var isOpeningOrHandshaking: Bool = false
    private var isAuthorizingBrowser: Bool = false
    private var controlAuthSummary: String = "pending"
    private var contentsAuthSummary: String = "pending"
    
    private func setupDeviceBrowser(forceRestart: Bool = false) {
        if forceRestart, let existing = self.deviceBrowser {
            existing.delegate = nil
            existing.stop()
            self.deviceBrowser = nil
        }
        
        guard self.deviceBrowser == nil, !isAuthorizingBrowser else { return }
        isAuthorizingBrowser = true
        
        let browser = ICDeviceBrowser()
        browser.delegate = self
        self.deviceBrowser = browser
        self.statusMessage = "Requesting iPadOS USB camera permissions..."
        
        #if os(iOS)
        browser.requestControlAuthorization { [weak self] controlStatus in
            browser.requestContentsAuthorization { [weak self] contentsStatus in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isAuthorizingBrowser = false
                    self.controlAuthSummary = controlStatus.rawValue
                    self.contentsAuthSummary = contentsStatus.rawValue
                    
                    if controlStatus == .denied || contentsStatus == .denied {
                        self.statusMessage = "\(CameraError.usbPermissionDenied.localizedDescription) (Control: \(controlStatus.rawValue), Contents: \(contentsStatus.rawValue))"
                    } else {
                        self.statusMessage = "Scanning USB bus (Auth: OK)..."
                    }
                    
                    // Restart browser cleanly after permissions are granted
                    self.deviceBrowser?.stop()
                    self.deviceBrowser?.start()
                    self.checkAlreadyDiscoveredDevices()
                }
            }
        }
        #else
        isAuthorizingBrowser = false
        self.statusMessage = "Scanning USB bus for camera..."
        browser.start()
        #endif
    }
    
    @MainActor
    private func checkAlreadyDiscoveredDevices() {
        guard cameraDevice == nil, let browser = deviceBrowser, let devices = browser.devices, !devices.isEmpty else { return }
        for dev in devices {
            deviceBrowser(browser, didAdd: dev, moreComing: false)
        }
    }
    
    func connect() async throws {
        // Unit test injection path
        if let transport = ptpTransport, cameraDevice == nil {
            try await performSonySDIOHandshake(using: transport)
            self.isConnected = true
            self.statusMessage = nil
            startKeepAliveLoop()
            return
        }
        
        if isConnected, ptpTransport != nil {
            return
        }
        
        await MainActor.run {
            if self.cameraDevice == nil {
                // Force a fresh ICDeviceBrowser scan when retrying with no device found
                self.setupDeviceBrowser(forceRestart: self.deviceBrowser != nil && !self.isAuthorizingBrowser)
            } else {
                self.checkAlreadyDiscoveredDevices()
            }
        }
        
        // Wait while authorization prompt is active
        for _ in 0..<40 {
            let authorizing = await MainActor.run { self.isAuthorizingBrowser }
            if !authorizing { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        
        // Wait up to 4.0s if USB enumeration or handshake is in progress
        for _ in 0..<16 {
            if isConnected, ptpTransport != nil {
                return
            }
            await MainActor.run {
                self.checkAlreadyDiscoveredDevices()
            }
            if cameraDevice != nil, !isOpeningOrHandshaking, !isConnected {
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        
        if isConnected, ptpTransport != nil {
            return
        }
        
        guard let device = cameraDevice else {
            if let msg = statusMessage, msg.contains("Mass Storage") {
                throw CameraError.usbMassStorageModeDetected
            }
            let count = deviceBrowser?.devices?.count ?? 0
            let browsing = deviceBrowser?.isBrowsing ?? false
            self.statusMessage = "No USB camera detected by iPadOS (devices: \(count), browsing: \(browsing), auth: \(controlAuthSummary)/\(contentsAuthSummary)). Try plugging camera directly into iPad without hub to test cable/port."
            throw CameraError.connectionFailed
        }
        
        // If didAdd / didOpenSessionWithError is already opening the session and running the handshake, wait for it
        if isOpeningOrHandshaking {
            for _ in 0..<20 {
                if isConnected || !isOpeningOrHandshaking { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if isConnected { return }
        }
        
        isOpeningOrHandshaking = true
        defer { isOpeningOrHandshaking = false }
        
        if !device.hasOpenSession {
            self.statusMessage = "Opening USB session with \(device.name ?? "Camera")..."
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.sessionOpenContinuation = continuation
                device.requestOpenSession()
            }
        }
        
        if isConnected, ptpTransport != nil {
            return
        }
        
        let transport = ICCameraPTPTransport(device: device)
        self.ptpTransport = transport
        self.statusMessage = "Running Sony PTP handshake with \(device.name ?? "Camera")..."
        try await performSonySDIOHandshake(using: transport)
        self.isConnected = true
        self.statusMessage = "Connected to \(device.name ?? "Sony Camera")"
        startKeepAliveLoop()
    }
    
    // MARK: - Sony 3-Phase SDIO Handshake
    
    private func performSonySDIOHandshake(using transport: PTPTransport) async throws {
        // Phase 1: SDIO_Connect(1, 0, 0) (with retry if camera is busy initializing USB)
        var rc1: UInt16 = 0
        for attempt in 0..<3 {
            let (_, code) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [1, 0, 0])
            rc1 = code
            if rc1 == SonyPTPResponseCode.ok.rawValue { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard rc1 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 1 returned 0x\(String(rc1, radix: 16))")
        }
        
        // Phase 2: SDIO_Connect(2, 0, 0)
        let (_, rc2) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [2, 0, 0])
        guard rc2 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 2 returned 0x\(String(rc2, radix: 16))")
        }
        
        // Query Extended Device Info (Protocol 3.00 = 0x012C, fallback to 1-arg or Protocol 2.00 = 0x00C8)
        let (_, rcExt) = try await commandQueue.execute(
            on: transport,
            opcode: .sdioGetExtDeviceInfo,
            params: [Self.sonyProtocolVersion3, 1]
        )
        if rcExt != SonyPTPResponseCode.ok.rawValue {
            let (_, rcExt1Arg) = try await commandQueue.execute(
                on: transport,
                opcode: .sdioGetExtDeviceInfo,
                params: [Self.sonyProtocolVersion3]
            )
            if rcExt1Arg != SonyPTPResponseCode.ok.rawValue {
                _ = try? await commandQueue.execute(
                    on: transport,
                    opcode: .sdioGetExtDeviceInfo,
                    params: [0x00C8]
                )
            }
        }
        
        // Phase 3: SDIO_Connect(3, 0, 0)
        let (_, rc3) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [3, 0, 0])
        guard rc3 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 3 returned 0x\(String(rc3, radix: 16))")
        }
        
        // 1. Set Priority Mode to Camera Priority (0xD25A = 0) so physical camera dials (shutter speed, aperture, ISO) remain fully controllable
        try? await setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
        
        // 2. Set default PC+Camera save destination (0xD222 = 0x0011) FIRST so 0xD269 and 0xD268 are unlocked,
        //    then enforce 2M JPEG transfer format (0xD269 = 2 JPEG Only, 0xD268 = 2 2M).
        try? await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
        try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
        try? await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
        
        // 3. Drain any leftover image(s) in camera RAM (0xFFFFC001) from a prior interrupted session
        await drainStaleRAMObjectIfNeeded(using: transport)
    }
    
    private func drainStaleRAMObjectIfNeeded(using transport: PTPTransport) async {
        for _ in 0..<4 {
            guard let (propData, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
                  let objectInMem = SonyPTPPacket.parseObjectInMemory(from: propData),
                  objectInMem >= 0x8000 else {
                return
            }
            _ = try? await commandQueue.execute(
                on: transport,
                opcode: .getObjectInfo,
                params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
            )
            _ = try? await commandQueue.execute(
                on: transport,
                opcode: .getObject,
                params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
            )
            if objectInMem <= 0x8001 {
                return
            }
        }
    }
    
    // MARK: - Property & Control Helpers
    
    private func setDevicePropertyUInt8(_ prop: SonyPTPPropertyCode, value: UInt8, using transport: PTPTransport) async throws {
        let payload = Data([value])
        _ = try await commandQueue.execute(
            on: transport,
            opcode: .sdioSetExtDevicePropValue,
            params: [UInt32(prop.rawValue)],
            outData: payload
        )
    }
    
    private func setDevicePropertyUInt16(_ prop: SonyPTPPropertyCode, value: UInt16, using transport: PTPTransport) async throws {
        var payload = Data(capacity: 2)
        payload.appendLittleEndian(value)
        _ = try await commandQueue.execute(
            on: transport,
            opcode: .sdioSetExtDevicePropValue,
            params: [UInt32(prop.rawValue)],
            outData: payload
        )
    }
    
    private func sendControlUInt16(_ control: SonyPTPPropertyCode, value: UInt16, using transport: PTPTransport) async throws {
        var payload = Data(capacity: 2)
        payload.appendLittleEndian(value)
        _ = try await commandQueue.execute(
            on: transport,
            opcode: .sdioControlDevice,
            params: [UInt32(control.rawValue)],
            outData: payload
        )
    }
    
    // MARK: - Dual Storage Routing & Zero-Lag MF Shutter
    
    func prepareForCapture(mode: CaptureMode) async throws {
        guard let transport = ptpTransport, isConnected else {
            throw CameraError.connectionFailed
        }
        
        await commandQueue.beginCaptureScope()
        do {
            switch mode {
            case .gif:
                // GIF Mode: Route exclusively to iPad RAM (0x0001) so SD card is NEVER touched.
                try await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcOnly.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
                try await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
                
            case .standard:
                // Standard Mode: Archive Full-Res on SD Card + transfer 2M JPEG to iPad (0x0011)
                try await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
                try await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
            }
            await commandQueue.endCaptureScope()
        } catch {
            await commandQueue.endCaptureScope()
            throw error
        }
    }
    
    func finishCaptureSequence(mode: CaptureMode) async {
        guard let transport = ptpTransport else { return }
        await commandQueue.beginCaptureScope()
        if mode == .gif {
            // Restore default PC + Camera destination
            try? await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
            try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
            try? await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
        }
        await commandQueue.endCaptureScope()
    }
    
    // MARK: - Capture & RAM Buffer Ingestion (0xFFFFC001)
    
    private func triggerShutterAndConfirmStart(
        using transport: PTPTransport,
        s1SettleNs: UInt64,
        s2MinHoldNs: UInt64,
        s2MaxHoldSec: TimeInterval
    ) async throws -> UInt16 {
        // Assert S1 (0xD2C1 = 2) and wait for half-press / AE lock registration
        try await sendControlUInt16(.shutterHalfRelease, value: 2, using: transport)
        try? await Task.sleep(nanoseconds: s1SettleNs)
        
        var latestObjState: UInt16 = 0
        do {
            // Assert S2 (0xD2C2 = 2 -> fires mechanical shutter & strobe)
            try await sendControlUInt16(.shutterRelease, value: 2, using: transport)
            try? await Task.sleep(nanoseconds: s2MinHoldNs)
            
            // Poll 0xD215 while S2 is held so if the camera needs ~100-350ms to meter AE / stop down
            // aperture blades in Aperture Priority before firing, S2 stays pressed until capture starts (0xD215 > 0).
            let holdDeadline = Date().addingTimeInterval(s2MaxHoldSec)
            while Date() < holdDeadline {
                if let (propBlob, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
                   let objState = SonyPTPPacket.parseObjectInMemory(from: propBlob) {
                    latestObjState = objState
                    if objState > 0 {
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
            
            // Sequentially release S2 = 1 followed by S1 = 1 so Live View runs freely between poses
            try await sendControlUInt16(.shutterRelease, value: 1, using: transport)
            try? await sendControlUInt16(.shutterHalfRelease, value: 1, using: transport)
        } catch {
            try? await sendControlUInt16(.shutterRelease, value: 1, using: transport)
            try? await sendControlUInt16(.shutterHalfRelease, value: 1, using: transport)
            throw error
        }
        return latestObjState
    }
    
    private func downloadCapturedJPEGFromRAM(
        initialObjState: UInt16,
        using transport: PTPTransport
    ) async throws -> Data? {
        var bestJPEGData: Data? = nil
        var currentObjState = initialObjState
        var safetyCount = 0
        
        while currentObjState >= 0x8000, safetyCount < 4 {
            safetyCount += 1
            
            // Query object info first (required by Sony firmware before GetObject on 0xFFFFC001)
            _ = try? await commandQueue.execute(
                on: transport,
                opcode: .getObjectInfo,
                params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
            )
            
            let (objData, rc) = try await commandQueue.execute(
                on: transport,
                opcode: .getObject,
                params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
            )
            
            if rc == SonyPTPResponseCode.ok.rawValue, !objData.isEmpty {
                let isJPEG = objData.count >= 2 && objData[objData.startIndex] == 0xFF && objData[objData.startIndex + 1] == 0xD8
                if isJPEG || bestJPEGData == nil {
                    bestJPEGData = objData
                }
            } else {
                break
            }
            
            if currentObjState <= 0x8001 {
                break
            }
            
            if let (propBlob, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
               let nextState = SonyPTPPacket.parseObjectInMemory(from: propBlob),
               nextState > 0x8000 {
                currentObjState = nextState
            } else {
                break
            }
        }
        
        return bestJPEGData
    }
    
    func takePicture() async throws -> [String] {
        guard let transport = ptpTransport, isConnected else {
            throw CameraError.connectionFailed
        }
        
        // Lock the capture & RAM ingestion sequence so 30 FPS Live View polling
        // pauses during S1/S2 + 0xFFFFC001 transfer, then immediately resumes between poses.
        await commandQueue.beginCaptureScope()
        
        do {
            // 1. Pre-drain any leftover object(s) in 0xFFFFC001 so we never read a stale frame or stall the shutter
            await drainStaleRAMObjectIfNeeded(using: transport)
            
            // 2. Trigger shutter with S1 settle + S2 hold until capture starts (0xD215 > 0)
            var observedObjState = try await triggerShutterAndConfirmStart(
                using: transport,
                s1SettleNs: 50_000_000,   // 50ms S1 half-press settle (allows AE lock in Aperture Priority)
                s2MinHoldNs: 70_000_000,  // 70ms minimum S2 hold
                s2MaxHoldSec: 0.35        // Up to 350ms S2 hold if camera is stopping down aperture / metering
            )
            
            // 3. Poll 0xD215 (ObjectInMemory):
            //    - 0x0000: shutter hasn't fired yet
            //    - 0x0001..<0x8000: shutter HAS fired; exposure/encoding in progress
            //    - >= 0x8000 (0x8001+): image ready in RAM at 0xFFFFC001
            let startWait = Date()
            let maxExposureWaitSec: TimeInterval = 10.0
            var didRetriggerShutter = false
            
            while Date().timeIntervalSince(startWait) < maxExposureWaitSec {
                if observedObjState >= 0x8000 {
                    if let jpegData = try await downloadCapturedJPEGFromRAM(
                        initialObjState: observedObjState,
                        using: transport
                    ) {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("sony_\(UUID().uuidString).jpg")
                        try jpegData.write(to: tempURL, options: .atomic)
                        await commandQueue.endCaptureScope()
                        return [tempURL.absoluteString]
                    }
                }
                
                // Fast re-trigger: if 0.40s has passed since S2 release and 0xD215 is STILL 0x0000
                // (meaning the camera ignored the first shutter pulse because it was busy with SD card / Live View),
                // re-pulse S1/S2 immediately instead of waiting 6+ seconds to time out!
                if !didRetriggerShutter,
                   observedObjState == 0,
                   Date().timeIntervalSince(startWait) >= 0.40 {
                    didRetriggerShutter = true
                    observedObjState = try await triggerShutterAndConfirmStart(
                        using: transport,
                        s1SettleNs: 90_000_000,
                        s2MinHoldNs: 130_000_000,
                        s2MaxHoldSec: 0.55
                    )
                    continue
                }
                
                try await Task.sleep(nanoseconds: 40_000_000) // 40ms poll interval
                if let (propBlob, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
                   let stateVal = SonyPTPPacket.parseObjectInMemory(from: propBlob) {
                    observedObjState = stateVal
                }
            }
            
            await commandQueue.endCaptureScope()
            throw CameraError.timeout
        } catch {
            await commandQueue.endCaptureScope()
            throw error
        }
    }
    
    // MARK: - Paced 30 FPS PTP Live View (0xFFFFC002) & Sleep Prevention
    
    func startLiveView() async throws {
        stopLiveView()
        guard ptpTransport != nil, isConnected else { return }
        
        liveViewTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let targetFrameIntervalNs: UInt64 = 33_000_000 // ~30 FPS
            
            while !Task.isCancelled {
                let frameStart = DispatchTime.now().uptimeNanoseconds
                
                if await self.commandQueue.isBusyWithCaptureOrConfig {
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    continue
                }
                
                guard let transport = await MainActor.run(body: { self.ptpTransport }) else { break }
                
                if let (payload, rc) = try? await self.commandQueue.execute(
                    on: transport,
                    opcode: .getObject,
                    params: [SonyPTPHostHandle.liveViewFrameRAM.rawValue],
                    highPriority: false
                ), rc == SonyPTPResponseCode.ok.rawValue {
                    
                    let decodedImage: UIImage? = autoreleasepool {
                        guard let jpegData = SonyPTPPacket.extractLiveViewJPEG(from: payload) else {
                            return nil
                        }
                        return UIImage(data: jpegData)
                    }
                    
                    if let image = decodedImage {
                        await MainActor.run {
                            self._previewStream.send(image)
                        }
                    }
                }
                
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart
                if elapsed < targetFrameIntervalNs {
                    try? await Task.sleep(nanoseconds: targetFrameIntervalNs - elapsed)
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
    }
    
    func stopLiveView() {
        liveViewTask?.cancel()
        liveViewTask = nil
    }
    
    /// Sends a lightweight periodic PTP status query every 60s to prevent Sony camera auto-sleep.
    private func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard let self = self, !Task.isCancelled else { break }
                if await self.commandQueue.isBusyWithCaptureOrConfig { continue }
                guard let transport = await MainActor.run(body: { self.ptpTransport }) else { break }
                _ = try? await self.commandQueue.execute(
                    on: transport,
                    opcode: .sdioGetAllExtDevicePropInfo,
                    highPriority: false
                )
            }
        }
    }
    
    func fetchImage(url: String) async throws -> Data {
        if let parsedURL = URL(string: url), parsedURL.isFileURL {
            return try Data(contentsOf: parsedURL)
        }
        let fileURL = URL(fileURLWithPath: url)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        throw CameraError.invalidResponse
    }
    
    func checkConnection() async -> Bool {
        return isConnected && (cameraDevice?.hasOpenSession == true || ptpTransport != nil)
    }
    
    // MARK: - ICDeviceBrowserDelegate (Hot-Plug & App Background/Foreground Suspension)
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let devName = device.name ?? "Unknown USB Device"
        
        if device.transportType == ICDeviceTransport.transportTypeMassStorage.rawValue {
            self.statusMessage = CameraError.usbMassStorageModeDetected.localizedDescription
            self.isConnected = false
            return
        }
        
        guard let camera = device as? ICCameraDevice else {
            self.statusMessage = "Detected non-PTP USB device: \(devName)"
            return
        }
        
        self.cameraDevice = camera
        camera.delegate = self
        
        if !camera.hasOpenSession && !isOpeningOrHandshaking {
            isOpeningOrHandshaking = true
            self.statusMessage = "Found \(devName) — opening USB PTP session..."
            camera.requestOpenSession()
        }
    }
    
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == cameraDevice {
            handleDeviceDisconnect()
        }
    }
    
    #if os(iOS)
    func deviceBrowserWillSuspendOperations(_ browser: ICDeviceBrowser) {
        // Operator switched out of the app on the iPad: pause Live View cleanly before iOS suspends USB
        wasLiveViewRunningBeforeSuspend = (liveViewTask != nil)
        stopLiveView()
    }
    
    func deviceBrowserDidResumeOperations(_ browser: ICDeviceBrowser) {
        // Operator switched back to Photobooth2: seamlessly resume Live View
        if wasLiveViewRunningBeforeSuspend, isConnected {
            Task { @MainActor in
                try? await self.startLiveView()
            }
        }
    }
    
    func deviceBrowserDidCancelSuspendOperations(_ browser: ICDeviceBrowser) {
        if wasLiveViewRunningBeforeSuspend, isConnected, liveViewTask == nil {
            Task { @MainActor in
                try? await self.startLiveView()
            }
        }
    }
    #endif
    
    func didRemove(_ device: ICDevice) {
        if device == cameraDevice {
            handleDeviceDisconnect()
        }
    }
    
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error = error {
            isOpeningOrHandshaking = false
            self.statusMessage = "USB Session Error: \(error.localizedDescription)"
            sessionOpenContinuation?.resume(throwing: error)
            sessionOpenContinuation = nil
            return
        }
        
        // If `connect()` is waiting on `sessionOpenContinuation`, let `connect()` perform the single handshake.
        if let continuation = sessionOpenContinuation {
            sessionOpenContinuation = nil
            continuation.resume(returning: ())
            return
        }
        
        // Otherwise (hot-plug via `deviceBrowser(_:didAdd:)`), perform the single handshake here.
        Task { @MainActor in
            defer { self.isOpeningOrHandshaking = false }
            guard !self.isConnected, let camera = device as? ICCameraDevice else { return }
            let devName = camera.name ?? "Sony Camera"
            let transport = ICCameraPTPTransport(device: camera)
            self.ptpTransport = transport
            self.statusMessage = "Session open with \(devName) — running Sony PTP handshake..."
            do {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms USB pipe settle
                try await self.performSonySDIOHandshake(using: transport)
                self.statusMessage = "Connected to \(devName)"
                self.isConnected = true
                self.startKeepAliveLoop()
            } catch {
                self.statusMessage = "PTP Handshake Error: \(error.localizedDescription)"
                self.isConnected = false
            }
        }
    }
    
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        if device == cameraDevice {
            handleDeviceDisconnect()
        }
    }
    
    private func handleDeviceDisconnect() {
        stopLiveView()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        isOpeningOrHandshaking = false
        ptpTransport = nil
        cameraDevice = nil
        isConnected = false
        statusMessage = "USB camera disconnected."
    }
    
    // Required ICCameraDeviceDelegate conformance
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
