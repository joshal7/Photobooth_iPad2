import Foundation
import Combine
import UIKit
import CoreImage
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
    
    private nonisolated final class OneShotGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false
        func tryAcquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didFire { return false }
            didFire = true
            return true
        }
    }
    
    nonisolated init(device: ICCameraDevice) {
        self.device = device
    }
    
    nonisolated func sendPTPCommand(_ commandPacket: Data, outData: Data?) async throws -> (inData: Data, responsePacket: Data) {
        guard let device = device, device.hasOpenSession else {
            throw CameraError.connectionFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = OneShotGate()
            
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6.0) {
                if gate.tryAcquire() {
                    continuation.resume(throwing: CameraError.timeout)
                }
            }
            
            device.requestSendPTPCommand(commandPacket, outData: outData) { inData, responsePacket, error in
                guard gate.tryAcquire() else { return }
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
    nonisolated private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    
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
    private var autoDiscoveryTask: Task<Void, Never>?
    private var wasLiveViewRunningBeforeSuspend: Bool = false
    private var sessionOpenContinuation: CheckedContinuation<Void, Error>?
    private var sessionOpenToken: UUID?
    
    init(injectedTransport: PTPTransport? = nil) {
        self.ptpTransport = injectedTransport
        super.init()
        if injectedTransport == nil {
            setupDeviceBrowser()
            startAutoDiscoveryLoop()
        }
    }
    
    deinit {
        liveViewTask?.cancel()
        keepAliveTask?.cancel()
        autoDiscoveryTask?.cancel()
        if let pending = sessionOpenContinuation {
            sessionOpenContinuation = nil
            pending.resume(throwing: CameraError.connectionFailed)
        }
        cameraDevice?.delegate = nil
        deviceBrowser?.delegate = nil
        deviceBrowser?.stop()
    }
    
    func shutdown() {
        stopLiveView()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        autoDiscoveryTask?.cancel()
        autoDiscoveryTask = nil
        if let pending = sessionOpenContinuation {
            sessionOpenContinuation = nil
            sessionOpenToken = nil
            pending.resume(throwing: CameraError.connectionFailed)
        }
        isOpeningOrHandshaking = false
        ptpTransport = nil
        cameraDevice?.delegate = nil
        cameraDevice = nil
        deviceBrowser?.delegate = nil
        deviceBrowser?.stop()
        deviceBrowser = nil
        isConnected = false
    }
    
    private var isOpeningOrHandshaking: Bool = false {
        didSet {
            handshakingStartTime = isOpeningOrHandshaking ? Date() : nil
        }
    }
    private var handshakingStartTime: Date? = nil
    private var isAuthorizingBrowser: Bool = false
    private var controlAuthSummary: String = "pending"
    private var contentsAuthSummary: String = "pending"
    
    private let backdropLock = NSLock()
    private nonisolated(unsafe) var currentBackdrop: BackdropItem = .none
    private nonisolated(unsafe) var activeCaptureMode: CaptureMode = .standard
    private nonisolated(unsafe) var latestLiveViewJPEGData: Data? = nil
    private nonisolated(unsafe) var latestLiveViewTimestampNs: UInt64 = 0
    
    nonisolated func updateSelectedBackdrop(_ backdrop: BackdropItem) {
        backdropLock.lock()
        currentBackdrop = backdrop
        backdropLock.unlock()
    }
    
    nonisolated private func setActiveCaptureMode(_ mode: CaptureMode) {
        backdropLock.lock()
        activeCaptureMode = mode
        backdropLock.unlock()
    }
    
    nonisolated private func currentBackdropAndMode() -> (BackdropItem, CaptureMode) {
        backdropLock.lock()
        defer { backdropLock.unlock() }
        return (currentBackdrop, activeCaptureMode)
    }
    
    nonisolated private func cacheLiveViewJPEG(_ data: Data) {
        backdropLock.lock()
        latestLiveViewJPEGData = data
        latestLiveViewTimestampNs = DispatchTime.now().uptimeNanoseconds
        backdropLock.unlock()
    }
    
    nonisolated private func recentLiveViewJPEG(maxAgeNs: UInt64) -> Data? {
        backdropLock.lock()
        defer { backdropLock.unlock() }
        guard let data = latestLiveViewJPEGData, latestLiveViewTimestampNs > 0 else {
            return nil
        }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs >= latestLiveViewTimestampNs, (nowNs - latestLiveViewTimestampNs) <= maxAgeNs else {
            return nil
        }
        return data
    }
    
    /// Continuously monitors USB discovery every 2.5s while disconnected so that if the camera was already
    /// plugged in when the app was sideloaded/launched (while iPadOS's `icdd` daemon is still releasing the
    /// prior process's USB session), it automatically re-polls and connects without needing a physical replug.
    private func startAutoDiscoveryLoop() {
        autoDiscoveryTask?.cancel()
        autoDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s
                guard let self = self, !Task.isCancelled else { break }
                await MainActor.run {
                    if self.isOpeningOrHandshaking,
                       let start = self.handshakingStartTime,
                       Date().timeIntervalSince(start) > 10.0 {
                        // Watchdog: reset stuck handshake state if iPadOS `icdd` dropped a session callback
                        self.isOpeningOrHandshaking = false
                        if let pending = self.sessionOpenContinuation {
                            self.sessionOpenContinuation = nil
                            self.sessionOpenToken = nil
                            pending.resume(throwing: CameraError.timeout)
                        }
                    }
                    
                    guard !self.isConnected,
                          !self.isOpeningOrHandshaking,
                          !self.isAuthorizingBrowser else { return }
                    // Skip in unit tests with injected transport
                    if self.ptpTransport != nil && self.cameraDevice == nil { return }
                    
                    self.checkAlreadyDiscoveredDevices()
                    
                    if let camera = self.cameraDevice {
                        if !camera.hasOpenSession {
                            self.isOpeningOrHandshaking = true
                            self.statusMessage = "Found \(camera.name ?? "Camera") — opening USB PTP session..."
                            camera.requestOpenSession()
                        } else if self.ptpTransport == nil {
                            // Session is already open at the OS level; trigger the PTP handshake
                            self.device(camera, didOpenSessionWithError: nil)
                        }
                    } else if let browser = self.deviceBrowser {
                        // Cycle ICDeviceBrowser to force iPadOS `icdd` to re-announce already-attached USB devices
                        browser.stop()
                        browser.start()
                        self.checkAlreadyDiscoveredDevices()
                    } else {
                        self.setupDeviceBrowser(forceRestart: true)
                    }
                }
            }
        }
    }
    
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
        let controlAuthSelector = NSSelectorFromString("requestControlAuthorizationWithCompletion:")
        let contentsAuthSelector = NSSelectorFromString("requestContentsAuthorizationWithCompletion:")
        if !ProcessInfo.processInfo.isiOSAppOnMac,
           browser.responds(to: controlAuthSelector),
           browser.responds(to: contentsAuthSelector) {
            browser.requestControlAuthorization { [weak self] controlStatus in
                browser.requestContentsAuthorization { [weak self] contentsStatus in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.isAuthorizingBrowser = false
                        self.controlAuthSummary = controlStatus.rawValue
                        self.contentsAuthSummary = contentsStatus.rawValue
                        
                        if controlStatus.rawValue.lowercased().contains("denied") || contentsStatus.rawValue.lowercased().contains("denied") {
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
        } else {
            isAuthorizingBrowser = false
            self.controlAuthSummary = "macOS"
            self.contentsAuthSummary = "macOS"
            self.statusMessage = "Scanning USB bus for camera..."
            browser.start()
            self.checkAlreadyDiscoveredDevices()
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
                if let existing = self.sessionOpenContinuation {
                    self.sessionOpenContinuation = nil
                    existing.resume(throwing: CameraError.connectionFailed)
                }
                let token = UUID()
                self.sessionOpenToken = token
                self.sessionOpenContinuation = continuation
                device.requestOpenSession()
                
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self = self,
                          self.sessionOpenToken == token,
                          let pending = self.sessionOpenContinuation else { return }
                    self.sessionOpenContinuation = nil
                    self.sessionOpenToken = nil
                    pending.resume(throwing: CameraError.timeout)
                }
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
        
        // 1. Temporarily set Priority Mode to PC Application (0xD25A = 1) so the camera accepts 0x9205 property writes
        try? await setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
        
        // 2. Set default PC+Camera save destination (0xD222 = 0x0011) FIRST so 0xD269 and 0xD268 are unlocked,
        //    enforce 2M JPEG transfer format (0xD269 = 2 JPEG Only, 0xD268 = 2 2M),
        //    and set Live View Setting Effect OFF (0xD231 = 2) so the camera auto-brightens Live View prior to flash.
        try? await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
        try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
        try? await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
        try? await setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
        
        // 3. Return Priority Mode to Camera (0xD25A = 0) so physical shutter speed, aperture, and ISO dials remain unlocked
        try? await setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
        
        // 4. Drain any leftover image(s) in camera RAM (0xFFFFC001) from a prior interrupted session
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
        setActiveCaptureMode(mode)
        
        guard let transport = ptpTransport, isConnected else {
            throw CameraError.connectionFailed
        }
        
        await commandQueue.beginCaptureScope()
        do {
            try? await setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
            switch mode {
            case .gif:
                // GIF Mode: Route exclusively to iPad RAM (0x0001) so SD card is NEVER touched.
                try await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcOnly.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
                try await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
                
            case .standard:
                // Standard Mode: Archive Full-Res on SD Card + transfer 2M JPEG to iPad (0x0011)
                try await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
                try await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
                try? await setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
            }
            try? await setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
            await commandQueue.endCaptureScope()
        } catch {
            try? await setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
            await commandQueue.endCaptureScope()
            throw error
        }
    }
    
    func finishCaptureSequence(mode: CaptureMode) async {
        setActiveCaptureMode(.standard)
        
        guard let transport = ptpTransport else { return }
        await commandQueue.beginCaptureScope()
        if mode == .gif {
            // Restore default PC + Camera destination
            try? await setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
            try? await setDevicePropertyUInt16(.stillImageSaveDestination, value: SonySaveDestination.pcAndCamera.rawValue, using: transport)
            try? await setDevicePropertyUInt8(.pcSaveImageFormat, value: 2, using: transport)
            try? await setDevicePropertyUInt8(.pcSaveImageSize, value: SonyTransferImageSize.twoMegapixel.rawValue, using: transport)
            try? await setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
            try? await setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
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
    ) async throws -> (jpegData: Data, objectInfoData: Data?)? {
        var bestJPEGData: Data? = nil
        var bestObjectInfoData: Data? = nil
        var currentObjState = initialObjState
        var safetyCount = 0
        
        while currentObjState >= 0x8000, safetyCount < 4 {
            safetyCount += 1
            
            // Query object info first (required by Sony firmware before GetObject on 0xFFFFC001,
            // and provides the ISO 15740 ObjectInfo dataset containing the camera filename for Lock 1)
            let objInfoResult = try? await commandQueue.execute(
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
                let startsWithJPEG = objData.count >= 2 && objData[objData.startIndex] == 0xFF && objData[objData.startIndex + 1] == 0xD8
                if let extractedJPEG = SonyPTPPacket.extractCapturedJPEG(from: objData) {
                    if startsWithJPEG || bestJPEGData == nil {
                        bestJPEGData = extractedJPEG
                        bestObjectInfoData = objInfoResult?.0
                    }
                } else if bestJPEGData == nil {
                    bestJPEGData = objData
                    bestObjectInfoData = objInfoResult?.0
                }
            } else {
                break
            }
            
            // Query 0xD215 again to see if another object (e.g. second slot in RAW+JPEG mode) is still in RAM
            if let (propBlob, _) = try? await commandQueue.execute(on: transport, opcode: .sdioGetAllExtDevicePropInfo),
               let nextState = SonyPTPPacket.parseObjectInMemory(from: propBlob),
               nextState >= 0x8000 {
                currentObjState = nextState
            } else {
                break
            }
        }
        
        guard let finalJPEG = bestJPEGData else { return nil }
        return (finalJPEG, bestObjectInfoData)
    }
    
    func takePicture() async throws -> [String] {
        guard let transport = ptpTransport, isConnected else {
            throw CameraError.connectionFailed
        }
        
        // Lock the capture & RAM ingestion sequence so 30 FPS Live View polling
        // pauses during S1/S2 + 0xFFFFC001 transfer, then immediately resumes between poses.
        await commandQueue.beginCaptureScope()
        var didEndCaptureScope = false
        
        do {
            // 1. Pre-drain any leftover object(s) in 0xFFFFC001 so we never read a stale frame or stall the shutter
            await drainStaleRAMObjectIfNeeded(using: transport)
            
            // 1b. Ensure we have a fresh (< 450ms old) hardware-auto-gained 0xFFFFC002 Live View frame cached
            //     BEFORE asserting S1 so that if a capture is taken in extreme low light without a flash
            //     (where the 0xFFFFC001 still capture is crushed to 0..2/255 monochrome), we can recover
            //     the camera's BIONZ XR hardware-exposed Live View frame while keeping zero 0xFFFFC002
            //     commands interleaved between S1 Down and GetObject(0xFFFFC001).
            if recentLiveViewJPEG(maxAgeNs: 450_000_000) == nil {
                if let (lvPayload, lvRC) = try? await commandQueue.execute(
                    on: transport,
                    opcode: .getObject,
                    params: [SonyPTPHostHandle.liveViewFrameRAM.rawValue]
                ), lvRC == SonyPTPResponseCode.ok.rawValue,
                   let lvJPEG = SonyPTPPacket.extractLiveViewJPEG(from: lvPayload) {
                    cacheLiveViewJPEG(lvJPEG)
                }
            }
            
            // 2. Trigger shutter with S1 settle + S2 hold until capture starts (0xD215 > 0)
            var observedObjState = try await triggerShutterAndConfirmStart(
                using: transport,
                s1SettleNs: 120_000_000,  // 120ms S1 half-press settle for Auto-ISO / AE convergence
                s2MinHoldNs: 70_000_000,  // 70ms minimum S2 hold
                s2MaxHoldSec: 0.35        // Up to 350ms S2 hold if camera is stopping down aperture / metering
            )
            
            // 3. Poll 0xD215 (ObjectInMemory):
            let startWait = Date()
            let maxExposureWaitSec: TimeInterval = 10.0
            var didRetriggerShutter = false
            
            while Date().timeIntervalSince(startWait) < maxExposureWaitSec {
                if observedObjState >= 0x8000 {
                    if let downloaded = try await downloadCapturedJPEGFromRAM(
                        initialObjState: observedObjState,
                        using: transport
                    ) {
                        // Release USB commandQueue immediately once RAM transfer completes so 30 FPS Live View
                        // resumes right away while .captureAccurate segmentation & JPEG write finish in parallel.
                        didEndCaptureScope = true
                        await commandQueue.endCaptureScope()
                        let (backdrop, mode) = currentBackdropAndMode()
                        let fallbackLVData = self.recentLiveViewJPEG(maxAgeNs: 3_000_000_000)
                        let normalizedData = await Task.detached(priority: .userInitiated) {
                            Self.normalizeAndAutoExposeCapturedJPEG(
                                downloaded.jpegData,
                                objectInfoData: downloaded.objectInfoData,
                                backdrop: backdrop,
                                captureMode: mode,
                                fallbackLiveViewJPEG: fallbackLVData
                            )
                        }.value
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("sony_\(UUID().uuidString).jpg")
                        try normalizedData.write(to: tempURL, options: .atomic)
                        return [tempURL.absoluteString]
                    }
                }
                
                // Fast re-trigger: if 0.40s has passed since S2 release and 0xD215 is STILL 0x0000
                if !didRetriggerShutter,
                   observedObjState == 0,
                   Date().timeIntervalSince(startWait) >= 0.40 {
                    didRetriggerShutter = true
                    observedObjState = try await triggerShutterAndConfirmStart(
                        using: transport,
                        s1SettleNs: 120_000_000,
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
            
            didEndCaptureScope = true
            await commandQueue.endCaptureScope()
            throw CameraError.timeout
        } catch {
            if !didEndCaptureScope {
                await commandQueue.endCaptureScope()
            }
            throw error
        }
    }
    
    /// Decodes a JPEG buffer into an upright `CGImage` with EXIF orientation baked in.
    nonisolated private static func decodeUprightCGImage(from jpegData: Data) -> CGImage? {
        if let src = CGImageSourceCreateWithData(jpegData as CFData, nil) {
            let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let maxDim = max(w, h, 8192)
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceThumbnailMaxPixelSize: maxDim as NSNumber
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return cg
            }
        }
        return UIImage(data: jpegData)?.cgImage
    }
    
    /// Resamples a `CGImage` to the specified dimensions using high-quality interpolation without edge ringing.
    nonisolated private static func resampleCGImage(_ cgImage: CGImage, toWidth targetWidth: Int, height targetHeight: Int) -> CGImage {
        guard targetWidth > 0, targetHeight > 0,
              (cgImage.width != targetWidth || cgImage.height != targetHeight) else {
            return cgImage
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return ctx.makeImage() ?? cgImage
    }
    
    /// Re-encodes the downloaded 2MP Sony transfer payload as a clean, standard iOS JFIF JPEG:
    /// 1. Records the Triple-Lock metadata (`ptpFilename`, EXIF `DateTimeOriginal`, `8x8` RGB signature) in `BackdropManifestStore`
    ///    in `.standard` Photo Mode when a backdrop is active (since `.standard` uses `pcAndCamera` `0x0011` to save full-res JPEGs
    ///    to the camera SD card, whereas `.gif` uses `pcOnly` `0x0001` RAM-only transfer).
    /// 2. If the `0xFFFFC001` still capture is crushed below the 8-bit quantization floor (`rawSubjectY < 0.016 && rawP90Y < 0.048`,
    ///    e.g. shooting at manual strobe settings `1/125s, f/10, ISO 200` in a dark room without flash, where the camera's 8-bit JPEG
    ///    crushes pixels to `0..2/255` and zeroes out `Cb/Cr` chroma), seamlessly recovers the contemporaneous `0xFFFFC002` Live View
    ///    frame (which the Sony BIONZ XR ISP hardware-auto-gains in 14-bit raw sensor space when `0xD231 = 2` Setting Effect OFF is active).
    /// 3. Horizontally mirrors the external camera subject so captured photos and GIF frames match the mirrored Live View preview
    ///    while keeping any composited foreground frame text un-reversed.
    /// 4. Auto-exposes dark or dim captures on the mirrored subject image FIRST using our ISP luminance-driven de-blocking pipeline.
    /// 5. In `.standard` Photo Mode with an active backdrop, composites the Background + Foreground with `.captureAccurate` segmentation.
    /// 6. In `.gif` Mode, saves the mirrored, auto-exposed frame so `GIFService.createGIF` can equalize burst luminance
    ///    first before applying `.captureAccurate` backdrop compositing (preventing any border/backdrop brightness flicker).
    nonisolated static func normalizeAndAutoExposeCapturedJPEG(
        _ rawData: Data,
        objectInfoData: Data? = nil,
        backdrop: BackdropItem = .none,
        captureMode: CaptureMode = .standard,
        additionalSearchDirectories: [URL] = [],
        fallbackLiveViewJPEG: Data? = nil
    ) -> Data {
        return autoreleasepool {
            let extracted = SonyPTPPacket.extractCapturedJPEG(from: rawData) ?? rawData
            
            guard let decodedRawCG = decodeUprightCGImage(from: extracted) else {
                return extracted
            }
            
            var unmirroredRawCG = BackdropCompositorService.cropToLandscapeThreeByTwo(decodedRawCG)
            let ciContext = Self.sharedCIContext
            
            // Record Triple-Lock manifest entry using `unmirroredRawCG` (upright, un-mirrored, pre-exposure boost)
            // so its 8x8 RGB signature matches the un-boosted SD card DSC0xxxx.JPG file even in dim lighting conditions.
            // Only record in `.standard` Photo Mode where the Sony camera writes to the SD card (`0x0011`).
            // Also record `.none` ("Original") captures when camera metadata is present so No-Background photos
            // explicitly claim their SD card filename/timestamp and supersede any deleted/formatted prior shots.
            if captureMode == .standard {
                BackdropManifestStore.shared.recordCapture(
                    uncompositedCGImage: unmirroredRawCG,
                    rawJPEGData: extracted,
                    ptpObjectInfoData: objectInfoData,
                    backdrop: backdrop
                )
            }
            
            // Check if the 0xFFFFC001 still capture is severely underexposed relative to the Sony camera's
            // hardware-auto-gained 0xFFFFC002 Live View frame (when 0xD231 = 2 Setting Effect OFF is active).
            let (rawSubjectY, rawP90Y) = measureSceneLuminance(unmirroredRawCG)
            var usedLiveViewAutogain = false
            if rawSubjectY < 0.055, rawP90Y < 0.16,
               let lvJPEG = fallbackLiveViewJPEG,
               let lvDecodedCG = decodeUprightCGImage(from: lvJPEG) {
                let lvThreeByTwoCG = BackdropCompositorService.cropToLandscapeThreeByTwo(lvDecodedCG)
                let (lvSubjectY, lvP90Y) = measureSceneLuminance(lvThreeByTwoCG)
                if lvSubjectY >= max(0.08, rawSubjectY * 1.8) || lvP90Y >= max(0.18, rawP90Y * 1.8) {
                    unmirroredRawCG = resampleCGImage(
                        lvThreeByTwoCG,
                        toWidth: unmirroredRawCG.width,
                        height: unmirroredRawCG.height
                    )
                    usedLiveViewAutogain = true
                }
            }
            
            // Horizontally mirror the external camera subject so captured photos and GIF frames match the
            // mirrored Live View preview while any subsequently composited foreground frame text stays un-reversed.
            let mirroredRawCG = BackdropCompositorService.mirrorCGImageHorizontally(unmirroredRawCG, ciContext: ciContext)
            let exposedCG = autoExposeCapturedCGImage(
                mirroredRawCG,
                ciContext: ciContext,
                forceLightDegrain: usedLiveViewAutogain
            )
            
            let finalCG: CGImage
            if captureMode == .standard && !backdrop.isNone {
                finalCG = BackdropCompositorService.composite(
                    cgImage: exposedCG,
                    backdrop: backdrop,
                    quality: .captureAccurate,
                    ciContext: ciContext,
                    additionalSearchDirectories: additionalSearchDirectories
                )
            } else {
                finalCG = exposedCG
            }
            
            let processedImage = UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
            return processedImage.jpegData(compressionQuality: 0.92) ?? extracted
        }
    }
    
    /// Decodes a raw Sony `0xFFFFC002` Live View JPEG frame, center-crops to landscape `3:2`,
    /// horizontally mirrors the subject (so the external camera acts like a natural mirror for guests),
    /// auto-exposes dark frames, and composites any active background/foreground (keeping foreground text un-reversed).
    nonisolated static func processLiveViewJPEG(
        _ jpegData: Data,
        backdrop: BackdropItem = .none,
        ciContext: CIContext,
        additionalSearchDirectories: [URL] = []
    ) -> (UIImage, Double)? {
        guard let rawImage = UIImage(data: jpegData),
              let rawCG = rawImage.cgImage else {
            return nil
        }
        let threeByTwoCG = BackdropCompositorService.cropToLandscapeThreeByTwo(rawCG)
        let mirroredCG = BackdropCompositorService.mirrorCGImageHorizontally(threeByTwoCG, ciContext: ciContext)
        let normalizedLiveUI = UIImage(cgImage: mirroredCG, scale: 1.0, orientation: .up)
        let (exposedImage, rawLuma) = Self.autoExposeLiveViewIfNeeded(normalizedLiveUI, ciContext: ciContext)
        guard !backdrop.isNone, let exposedCG = exposedImage.cgImage else {
            return (exposedImage, rawLuma)
        }
        let compositedCG = BackdropCompositorService.composite(
            cgImage: exposedCG,
            backdrop: backdrop,
            quality: .liveFast,
            ciContext: ciContext,
            additionalSearchDirectories: additionalSearchDirectories
        )
        let finalUI = UIImage(cgImage: compositedCG, scale: 1.0, orientation: .up)
        return (finalUI, rawLuma)
    }
    
    /// Auto-exposes a captured `UIImage` (called once during JPEG normalization in `takePicture()`)
    /// using a fast, single-pass GPU exposure and highlight roll-off pipeline.
    nonisolated static func autoExposeCapturedUIImage(_ image: UIImage, ciContext: CIContext? = nil) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let ctx = ciContext ?? Self.sharedCIContext
        let boostedCG = autoExposeCapturedCGImage(cgImage, ciContext: ctx)
        if boostedCG === cgImage {
            return image
        }
        return UIImage(cgImage: boostedCG, scale: image.scale, orientation: image.imageOrientation)
    }
    
    /// Auto-exposes a captured `CGImage` in a single, continuous GPU pass:
    nonisolated static func autoExposeCapturedCGImage(
        _ cgImage: CGImage,
        ciContext: CIContext,
        forceLightDegrain: Bool = false
    ) -> CGImage {
        let (boostedCG, _) = adjustCGImageExposureIfNeeded(
            cgImage,
            ciContext: ciContext,
            minRecoverableSrgbLuma: 0.0,
            targetSrgbLuma: 0.40,
            triggerThresholdSrgb: 0.38,
            maxEVBoost: 3.2,
            enableNoiseReduction: true,
            forceLightDegrain: forceLightDegrain
        )
        return boostedCG
    }
    
    // MARK: - Paced 30 FPS PTP Live View (0xFFFFC002) & Sleep Prevention
    
    func startLiveView() async throws {
        stopLiveView()
        guard ptpTransport != nil, isConnected else { return }
        
        liveViewTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let targetFrameIntervalNs: UInt64 = 33_000_000 // ~30 FPS
            let ciContext = Self.sharedCIContext
            var lastSettingEffectEnforceTime: UInt64 = 0
            
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
                    
                    let (activeBackdrop, _) = self.currentBackdropAndMode()
                    let result: (UIImage, Double)? = autoreleasepool {
                        guard let jpegData = SonyPTPPacket.extractLiveViewJPEG(from: payload) else {
                            return nil
                        }
                        self.cacheLiveViewJPEG(jpegData)
                        return Self.processLiveViewJPEG(
                            jpegData,
                            backdrop: activeBackdrop,
                            ciContext: ciContext
                        )
                    }
                    
                    if let (image, meanLuma) = result {
                        await MainActor.run {
                            self._previewStream.send(image)
                        }
                        
                        // If the operator rotated the physical mode dial (e.g. from M to Custom "1"),
                        // the camera reloads Memory Recall 1 which resets Live View Setting Effect (0xD231) to ON (1),
                        // causing the camera to send dark Live View frames. Immediately re-assert Setting Effect OFF (2)!
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        if meanLuma < 0.16,
                           nowNs - lastSettingEffectEnforceTime > 2_000_000_000,
                           !(await self.commandQueue.isBusyWithCaptureOrConfig) {
                            lastSettingEffectEnforceTime = nowNs
                            try? await self.setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
                            try? await self.setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
                            try? await self.setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
                        }
                    }
                }
                
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart
                if elapsed < targetFrameIntervalNs {
                    try? await Task.sleep(nanoseconds: targetFrameIntervalNs - elapsed)
                } else {
                    try? await Task.sleep(nanoseconds: 1_500_000)
                }
            }
        }
    }
    
    /// Ensures the iPad Live View preview remains bright and clearly visible for framing at 30 FPS
    /// without amplifying 8-bit quantization noise into black-and-white blocks while 0xD231 switches.
    nonisolated static func autoExposeLiveViewIfNeeded(_ image: UIImage, ciContext: CIContext) -> (UIImage, Double) {
        guard let cgImage = image.cgImage else { return (image, 0.5) }
        let (boostedCG, subjectSrgbLuma) = adjustCGImageExposureIfNeeded(
            cgImage,
            ciContext: ciContext,
            minRecoverableSrgbLuma: 0.025, // Avoid quantizing pitch-black frames during the 100ms while 0xD231 switches to 2
            targetSrgbLuma: 0.40,
            triggerThresholdSrgb: 0.36,
            maxEVBoost: 2.8,
            enableNoiseReduction: false
        )
        if boostedCG === cgImage {
            return (image, subjectSrgbLuma)
        }
        return (UIImage(cgImage: boostedCG, scale: image.scale, orientation: image.imageOrientation), subjectSrgbLuma)
    }
    
    /// Measures center-weighted sRGB scene luminance (`subjectSrgbY`, discarding only the top 2% specular
    /// pinpoints so small lamps don't skew dark-room metering) and the 98th-percentile highlight peak RGB channel
    /// (`p90SrgbY`, measuring `max(R, G, B)` at the 98th weighted percentile so studio strobe subjects against dark
    /// curtains or wearing dark costumes never overexpose or clip warm skin/red channels into yellow).
    nonisolated static func measureSceneLuminance(_ cgImage: CGImage) -> (subjectSrgbY: Double, p90SrgbY: Double) {
        let sampleSize = 48
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0.5, 0.7)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        
        struct Sample {
            let srgbY: Double
            let peakRGB: Double
            let weight: Double
        }
        
        var samples: [Sample] = []
        samples.reserveCapacity(sampleSize * sampleSize)
        var totalWeight = 0.0
        
        for y in 0..<sampleSize {
            let isCenterY = (y >= sampleSize / 5) && (y < (sampleSize * 4) / 5)
            for x in 0..<sampleSize {
                let isCenterX = (x >= sampleSize / 5) && (x < (sampleSize * 4) / 5)
                let offset = (y * sampleSize + x) * 4
                let r = Double(pixels[offset]) / 255.0
                let g = Double(pixels[offset + 1]) / 255.0
                let b = Double(pixels[offset + 2]) / 255.0
                
                let srgbY = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let peakRGB = max(r, max(g, b))
                let weight = (isCenterX && isCenterY) ? 2.0 : 1.0
                samples.append(Sample(srgbY: srgbY, peakRGB: peakRGB, weight: weight))
                totalWeight += weight
            }
        }
        
        // 99th weighted percentile of peak RGB channel max(R, G, B) protects lit faces/skin/clothing
        // even when a small subject occupies only 1.5%..5% of a dark studio backdrop curtain,
        // while still ignoring < 1% specular pinpoints (e.g. a small background bulb).
        let byPeak = samples.sorted { $0.peakRGB < $1.peakRGB }
        var cumWeight = 0.0
        var highlightPeakRGB = byPeak.last?.peakRGB ?? 0.8
        for s in byPeak {
            cumWeight += s.weight
            if cumWeight >= totalWeight * 0.99 {
                highlightPeakRGB = s.peakRGB
                break
            }
        }
        
        // Discard only the brightest 1% specular pinpoints when averaging scene luminance
        let byY = samples.sorted { $0.srgbY < $1.srgbY }
        let keepCount = max(1, Int(Double(byY.count) * 0.99))
        var weightedSrgbSum = 0.0
        var keptWeight = 0.0
        for i in 0..<keepCount {
            let s = byY[i]
            weightedSrgbSum += s.srgbY * s.weight
            keptWeight += s.weight
        }
        
        guard keptWeight > 0 else { return (0.5, highlightPeakRGB) }
        return (weightedSrgbSum / keptWeight, highlightPeakRGB)
    }
    
    /// Simple, robust, GPU-native Auto Exposure + very light GPU de-graining:
    /// - Runs 100% on the GPU via `CoreImage` in `< 4 ms` per frame (zero CPU pixel/blur loops).
    /// - Uses pure linear-light `CIExposureAdjust` bounded by the 98th-percentile peak RGB channel (`highlightPeakRGB`)
    ///   so well-exposed studio strobe portraits against dark curtains or dark costumes are left untouched (`ev = 0.0`)
    ///   and warm skin tones or red clothing never clip a single channel and shift toward yellow.
    /// - Applies gentle proportional chroma tempering via `CIColorControls` when lifting exposure so boosted images
    ///   never over-saturate, plus light `CINoiseReduction` (`inputNoiseLevel = 0.015`) on lifted low-light stills.
    nonisolated static func adjustCGImageExposureIfNeeded(
        _ cgImage: CGImage,
        ciContext: CIContext,
        minRecoverableSrgbLuma: Double,
        targetSrgbLuma: Double,
        triggerThresholdSrgb: Double,
        maxEVBoost: Double,
        enableNoiseReduction: Bool = true,
        forceLightDegrain: Bool = false
    ) -> (CGImage, Double) {
        let (subjectSrgbY, highlightPeakRGB) = measureSceneLuminance(cgImage)
        let highlightCeiling = enableNoiseReduction ? 0.72 : 0.76
        
        var ev: Double = 0.0
        if subjectSrgbY < triggerThresholdSrgb && subjectSrgbY >= minRecoverableSrgbLuma && highlightPeakRGB < highlightCeiling {
            let safeLuma = max(subjectSrgbY, 0.035)
            let lumaEV = min(max(log2(targetSrgbLuma / safeLuma) * 1.40, 0.0), maxEVBoost)
            let safePeak = max(highlightPeakRGB, 0.04)
            let highlightSafeEV = max(0.0, log2(highlightCeiling / safePeak) * 1.65)
            ev = min(lumaEV, highlightSafeEV)
        }
        
        let shouldApplyExposure = (ev > 0.04)
        let shouldApplyDegrain = enableNoiseReduction && min(cgImage.width, cgImage.height) >= 160 && (forceLightDegrain || ev > 0.65)
        
        guard shouldApplyExposure || shouldApplyDegrain else {
            return (cgImage, subjectSrgbY)
        }
        
        let ciInput = CIImage(cgImage: cgImage)
        var currentCI = ciInput
        
        // 1. Pure linear-light exposure gain bounded by highlight peak RGB headroom
        if shouldApplyExposure, let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(currentCI, forKey: kCIInputImageKey)
            exposureFilter.setValue(ev, forKey: kCIInputEVKey)
            if let out = exposureFilter.outputImage {
                currentCI = out
            }
        }
        
        // 2. Gently temper chroma saturation proportionally when lifting exposure so warm skin tones
        //    and shadow chroma noise never over-saturate or shift yellow when boosted.
        if shouldApplyExposure && (ev > 0.15 || subjectSrgbY < 0.10), let colorFilter = CIFilter(name: "CIColorControls") {
            let sat = max(0.88, min(1.0, 1.0 - ev * 0.035))
            colorFilter.setValue(currentCI, forKey: kCIInputImageKey)
            colorFilter.setValue(sat, forKey: kCIInputSaturationKey)
            if let out = colorFilter.outputImage {
                currentCI = out
            }
        }
        
        // 3. Very light GPU noise reduction on low-light still captures or Live View autogain fallback
        //    to take the edge off high-ISO graininess without softening facial details or creating halos.
        if shouldApplyDegrain, let nrFilter = CIFilter(name: "CINoiseReduction") {
            nrFilter.setValue(currentCI, forKey: kCIInputImageKey)
            nrFilter.setValue(0.015, forKey: "inputNoiseLevel")
            nrFilter.setValue(0.35, forKey: "inputSharpness")
            if let out = nrFilter.outputImage {
                currentCI = out.cropped(to: ciInput.extent)
            }
        }
        
        guard let outputCG = ciContext.createCGImage(currentCI, from: ciInput.extent) else {
            return (cgImage, subjectSrgbY)
        }
        
        return (outputCG, subjectSrgbY)
    }
    
    func stopLiveView() {
        liveViewTask?.cancel()
        liveViewTask = nil
    }
    
    /// Periodically polls Sony property table (0x9209) every 4s to prevent auto-sleep and immediately
    /// re-asserts Setting Effect OFF (0xD231 = 2) if the operator turns the physical camera mode dial (e.g. to "1").
    private func startKeepAliveLoop() {
        keepAliveTask?.cancel()
        keepAliveTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4s
                guard let self = self, !Task.isCancelled else { break }
                if await self.commandQueue.isBusyWithCaptureOrConfig { continue }
                guard let transport = await MainActor.run(body: { self.ptpTransport }) else { break }
                if let (propBlob, rc) = try? await self.commandQueue.execute(
                    on: transport,
                    opcode: .sdioGetAllExtDevicePropInfo,
                    highPriority: false
                ), rc == SonyPTPResponseCode.ok.rawValue {
                    let currentEffect = SonyPTPPacket.parseUInt8Property(.liveViewSettingEffect, from: propBlob)
                    if currentEffect == 1, !(await self.commandQueue.isBusyWithCaptureOrConfig) {
                        // Camera mode dial was turned (e.g. to Memory Recall "1") which reset 0xD231 to Setting Effect ON (1).
                        // Immediately restore Setting Effect OFF (2) and unlock physical dials (0xD25A = 0).
                        try? await self.setDevicePropertyUInt8(.priorityMode, value: 1, using: transport)
                        try? await self.setDevicePropertyUInt8(.liveViewSettingEffect, value: 2, using: transport)
                        try? await self.setDevicePropertyUInt8(.priorityMode, value: 0, using: transport)
                    }
                }
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
            self.ptpTransport = nil
            self.cameraDevice = nil
            self.statusMessage = "USB Session Error: \(error.localizedDescription) — retrying automatically..."
            sessionOpenToken = nil
            let pending = sessionOpenContinuation
            sessionOpenContinuation = nil
            pending?.resume(throwing: error)
            return
        }
        
        // If `connect()` is waiting on `sessionOpenContinuation`, let `connect()` perform the single handshake.
        if let continuation = sessionOpenContinuation {
            sessionOpenToken = nil
            sessionOpenContinuation = nil
            continuation.resume(returning: ())
            return
        }
        
        // Otherwise (hot-plug or auto-discovery loop), perform the single handshake here.
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
                self.statusMessage = "PTP Handshake Error: \(error.localizedDescription) — retrying..."
                self.isConnected = false
                self.ptpTransport = nil
                try? await camera.requestCloseSession()
                self.cameraDevice = nil
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
        sessionOpenToken = nil
        if let pending = sessionOpenContinuation {
            sessionOpenContinuation = nil
            pending.resume(throwing: CameraError.connectionFailed)
        }
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
