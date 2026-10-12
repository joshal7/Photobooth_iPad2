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
    
    private func setupDeviceBrowser() {
        let browser = ICDeviceBrowser()
        browser.delegate = self
        let maskRaw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if let mask = ICDeviceTypeMask(rawValue: maskRaw) {
            browser.browsedDeviceTypeMask = mask
        } else {
            browser.browsedDeviceTypeMask = .camera
        }
        self.deviceBrowser = browser
        
        #if os(iOS)
        browser.requestControlAuthorization { [weak self] controlStatus in
            browser.requestContentsAuthorization { [weak self] contentsStatus in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if controlStatus == .denied || contentsStatus == .denied {
                        self.statusMessage = CameraError.usbPermissionDenied.localizedDescription
                    }
                    self.deviceBrowser?.start()
                }
            }
        }
        #else
        browser.start()
        #endif
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
        
        // Wait up to 2.5s if USB enumeration is in progress
        if cameraDevice == nil {
            for _ in 0..<10 {
                if cameraDevice != nil { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        
        guard let device = cameraDevice else {
            if let msg = statusMessage, msg.contains("Mass Storage") {
                throw CameraError.usbMassStorageModeDetected
            }
            throw CameraError.connectionFailed
        }
        
        if !device.hasOpenSession {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.sessionOpenContinuation = continuation
                device.requestOpenSession()
            }
        }
        
        let transport = ICCameraPTPTransport(device: device)
        self.ptpTransport = transport
        try await performSonySDIOHandshake(using: transport)
        self.isConnected = true
        self.statusMessage = nil
        startKeepAliveLoop()
    }
    
    // MARK: - Sony 3-Phase SDIO Handshake
    
    private func performSonySDIOHandshake(using transport: PTPTransport) async throws {
        // Phase 1: SDIO_Connect(1, 0, 0)
        let (_, rc1) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [1, 0, 0])
        guard rc1 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 1 returned 0x\(String(rc1, radix: 16))")
        }
        
        // Phase 2: SDIO_Connect(2, 0, 0)
        let (_, rc2) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [2, 0, 0])
        guard rc2 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 2 returned 0x\(String(rc2, radix: 16))")
        }
        
        // Query Extended Device Info (Protocol 3.00 = 0x012C)
        _ = try await commandQueue.execute(
            on: transport,
            opcode: .sdioGetExtDeviceInfo,
            params: [Self.sonyProtocolVersion3, 1]
        )
        
        // Phase 3: SDIO_Connect(3, 0, 0)
        let (_, rc3) = try await commandQueue.execute(on: transport, opcode: .sdioConnect, params: [3, 0, 0])
        guard rc3 == SonyPTPResponseCode.ok.rawValue else {
            throw CameraError.ptpHandshakeFailed("SDIO Phase 3 returned 0x\(String(rc3, radix: 16))")
        }
        
        // 1. Set Priority Mode to PC Application (0xD25A = 1)
        try? await setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
        
        // 2. Enforce 2M JPEG transfer format (0xD269 = 2 JPEG Only, 0xD268 = 2 2M) and default PC+Camera save destination (0xD222 = 0x0011)
        try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
        try? await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
        try? await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
        
        // 3. Drain any leftover image in camera RAM (0xFFFFC001) from a prior interrupted session
        await drainStaleRAMObjectIfNeeded(using: transport)
    }
    
    private func drainStaleRAMObjectIfNeeded(using transport: PTPTransport) async {
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
                try await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
                
            case .standard:
                // Standard Mode: Archive Full-Res on SD Card + transfer 2M JPEG to iPad (0x0011)
                try await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
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
        }
        await commandQueue.endCaptureScope()
    }
    
    // MARK: - Capture & RAM Buffer Ingestion (0xFFFFC001)
    
    func takePicture() async throws -> [String] {
        guard let transport = ptpTransport, isConnected else {
            throw CameraError.connectionFailed
        }
        
        // Lock the capture & RAM ingestion sequence (~0.3s) so 30 FPS Live View polling
        // pauses during S1/S2 + 0xFFFFC001 transfer, then immediately resumes during the
        // 2.0s reposition window between GIF poses.
        await commandQueue.beginCaptureScope()
        
        do {
            // 1. Pre-drain any leftover object in 0xFFFFC001 so we never read a stale frame or stall the shutter
            await drainStaleRAMObjectIfNeeded(using: transport)
            
            // 2. Assert S1 (0xD2C1 = 2) and wait 25ms for half-press state registration
            try await sendControlUInt16(.shutterHalfRelease, value: 2, using: transport)
            try? await Task.sleep(nanoseconds: 25_000_000) // 25ms S1 settle
            
            // 3. Trigger Shutter Release (S2 press = 2 -> fires mechanical shutter & Godox X2T-S strobe)
            // and sequentially release S2 = 1 followed by S1 = 1 so Live View runs freely between poses.
            do {
                try await sendControlUInt16(.shutterRelease, value: 2, using: transport)
                try? await Task.sleep(nanoseconds: 40_000_000) // 40ms shutter hold
                try await sendControlUInt16(.shutterRelease, value: 1, using: transport)
                try? await sendControlUInt16(.shutterHalfRelease, value: 1, using: transport)
            } catch {
                try? await sendControlUInt16(.shutterHalfRelease, value: 1, using: transport)
                throw error
            }
            
            // 4. Allow 80ms for BIONZ XR JPEG encoding before polling 0xD215 (ObjectInMemory >= 0x8000)
            try? await Task.sleep(nanoseconds: 80_000_000)
            
            let deadline = Date().addingTimeInterval(6.0)
            while Date() < deadline {
                if let (propBlob, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
                   let objState = SonyPTPPacket.parseObjectInMemory(from: propBlob),
                   objState >= 0x8000 {
                    
                    // Query object info first (required by Sony firmware before GetObject on 0xFFFFC001)
                    _ = try? await commandQueue.execute(
                        on: transport,
                        opcode: .getObjectInfo,
                        params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
                    )
                    
                    let (jpegData, rc) = try await commandQueue.execute(
                        on: transport,
                        opcode: .getObject,
                        params: [SonyPTPHostHandle.capturedImageRAM.rawValue]
                    )
                    
                    if rc == SonyPTPResponseCode.ok.rawValue, !jpegData.isEmpty {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("sony_\(UUID().uuidString).jpg")
                        try jpegData.write(to: tempURL, options: .atomic)
                        await commandQueue.endCaptureScope()
                        return [tempURL.absoluteString]
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms poll interval
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
        let isSony = (device.usbVendorID == Self.sonyUSBVendorID)
            || (device.name?.localizedCaseInsensitiveContains("Sony") == true)
            || (device.name?.localizedCaseInsensitiveContains("ILCE") == true)
        
        guard isSony else { return }
        
        if device.transportType == ICDeviceTransport.transportTypeMassStorage.rawValue {
            self.statusMessage = CameraError.usbMassStorageModeDetected.localizedDescription
            self.isConnected = false
            return
        }
        
        guard let camera = device as? ICCameraDevice else { return }
        self.cameraDevice = camera
        camera.delegate = self
        camera.requestOpenSession()
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
            sessionOpenContinuation?.resume(throwing: error)
            sessionOpenContinuation = nil
            return
        }
        sessionOpenContinuation?.resume(returning: ())
        sessionOpenContinuation = nil
        
        Task { @MainActor in
            guard let camera = device as? ICCameraDevice else { return }
            let transport = ICCameraPTPTransport(device: camera)
            self.ptpTransport = transport
            do {
                try await self.performSonySDIOHandshake(using: transport)
                self.statusMessage = nil
                self.isConnected = true
                self.startKeepAliveLoop()
            } catch {
                self.statusMessage = error.localizedDescription
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
        ptpTransport = nil
        cameraDevice = nil
        isConnected = false
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
