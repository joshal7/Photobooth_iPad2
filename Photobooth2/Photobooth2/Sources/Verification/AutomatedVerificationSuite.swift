#if DEBUG
import Foundation
import Combine
import UIKit
import CoreImage
import ImageIO

/// Automated Tier 2 & Tier 3 Verification Suite executed when `--verify` is passed on launch.
enum AutomatedVerificationSuite {
    
    final class MockPTPTransport: PTPTransport, @unchecked Sendable {
        struct RecordedCommand: CustomStringConvertible, Sendable {
            let timestamp: Date
            let opcode: UInt16
            let parameters: [UInt32]
            let dataBytes: [UInt8]
            
            nonisolated var description: String {
                let opHex = String(format: "0x%04X", opcode)
                let paramsHex = parameters.map { String(format: "0x%X", $0) }.joined(separator: ",")
                let dataHex = dataBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                return "\(opHex)(\(paramsHex)) [\(dataHex)]"
            }
        }
        
        nonisolated private let lock = NSLock()
        nonisolated(unsafe) private var _commandLog: [RecordedCommand] = []
        nonisolated var commandLog: [RecordedCommand] {
            lock.lock()
            defer { lock.unlock() }
            return _commandLog
        }
        
        nonisolated(unsafe) var simulatedObjectInMemoryPollsBeforeReady: Int = 1
        nonisolated(unsafe) private var currentPollCount: Int = 0
        nonisolated(unsafe) var staleObjectInitiallyPresent: Bool = false
        nonisolated(unsafe) private var staleObjectDrained: Bool = false
        nonisolated let sampleJPEGData: Data
        
        init() {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
            let img = renderer.image { ctx in
                UIColor.systemBlue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            }
            self.sampleJPEGData = img.jpegData(compressionQuality: 0.8) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
        }
        
        nonisolated func resetLog() {
            lock.lock()
            defer { lock.unlock() }
            _commandLog.removeAll()
            currentPollCount = 0
            staleObjectDrained = false
        }
        
        nonisolated func sendPTPCommand(
            _ commandPacket: Data,
            outData: Data?
        ) async throws -> (inData: Data, responsePacket: Data) {
            return try handleCommandSync(commandPacket, outData: outData)
        }
        
        nonisolated private func handleCommandSync(
            _ commandPacket: Data,
            outData: Data?
        ) throws -> (inData: Data, responsePacket: Data) {
            let bytes = [UInt8](commandPacket)
            guard bytes.count >= 12 else {
                throw CameraError.invalidResponse
            }
            let opcode = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            let txID = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24)
            var params: [UInt32] = []
            var offset = 12
            while offset + 4 <= bytes.count {
                let p = UInt32(bytes[offset]) |
                        (UInt32(bytes[offset + 1]) << 8) |
                        (UInt32(bytes[offset + 2]) << 16) |
                        (UInt32(bytes[offset + 3]) << 24)
                params.append(p)
                offset += 4
            }
            let payloadBytes: [UInt8] = outData.map { [UInt8]($0) } ?? []
            
            lock.lock()
            defer { lock.unlock() }
            
            _commandLog.append(RecordedCommand(
                timestamp: Date(),
                opcode: opcode,
                parameters: params,
                dataBytes: payloadBytes
            ))
            
            let okResponse = SonyPTPPacket.buildResponse(code: .ok, transactionID: txID)
            
            switch SonyPTPOpcode(rawValue: opcode) {
            case .sdioConnect, .sdioGetExtDeviceInfo:
                return (Data(), okResponse)
                
            case .sdioGetAllExtDevicePropInfo:
                let isReady: UInt16
                if staleObjectInitiallyPresent && !staleObjectDrained {
                    isReady = 0x8001
                } else {
                    currentPollCount += 1
                    isReady = (currentPollCount >= simulatedObjectInMemoryPollsBeforeReady) ? 0x8001 : 0x0000
                }
                let propData = Self.buildMockDeviceInfoPayload(objectInMemoryValue: isReady)
                return (propData, okResponse)
                
            case .sdioSetExtDevicePropValue, .sdioControlDevice:
                if params.first == UInt32(SonyPTPPropertyCode.shutterRelease.rawValue),
                   payloadBytes == [0x02, 0x00] {
                    currentPollCount = 0
                }
                return (Data(), okResponse)
                
            case .getObjectInfo:
                return (Data(count: 64), okResponse)
                
            case .getObject:
                let handle = params.first ?? 0
                if handle == SonyPTPHostHandle.liveViewFrameRAM.rawValue {
                    let lvData = Self.buildMockLiveViewPayload(jpeg: sampleJPEGData)
                    return (lvData, okResponse)
                } else if handle == SonyPTPHostHandle.capturedImageRAM.rawValue {
                    if staleObjectInitiallyPresent && !staleObjectDrained {
                        staleObjectDrained = true
                    }
                    currentPollCount = 0
                    return (sampleJPEGData, okResponse)
                }
                return (Data(), okResponse)
                
            case .none:
                return (Data(), okResponse)
            }
        }
        
        nonisolated static func buildMockLiveViewPayload(jpeg: Data, headerOffset: UInt32 = 8) -> Data {
            var payload = Data()
            payload.appendLittleEndian(headerOffset)
            payload.appendLittleEndian(UInt32(jpeg.count))
            if headerOffset > 8 && headerOffset < 256 {
                payload.append(Data(count: Int(headerOffset - 8)))
            }
            payload.append(jpeg)
            return payload
        }
        
        nonisolated static func buildMockDeviceInfoPayload(objectInMemoryValue: UInt16) -> Data {
            var data = Data(count: 8)
            data.appendLittleEndian(SonyPTPPropertyCode.objectInMemory.rawValue)
            data.appendLittleEndian(UInt16(0x0004)) // PTP_DTC_UINT16
            data.append(contentsOf: [0x00, 0x01])   // GetSet, IsEnabled
            data.appendLittleEndian(UInt16(0x0000)) // FactoryDefault
            data.appendLittleEndian(objectInMemoryValue) // CurrentValue at offset +8 from PropCode
            data.append(0x00) // FormFlag
            return data
        }
    }
    
    static var passedAssertions = 0
    static var failedAssertions = 0
    
    private static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
        if condition() {
            passedAssertions += 1
            print("  ✅ PASS: \(message)")
        } else {
            failedAssertions += 1
            print("  ❌ FAIL [line \(line)]: \(message)")
        }
    }
    
    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
        if actual == expected {
            passedAssertions += 1
            print("  ✅ PASS: \(message) (\(actual))")
        } else {
            failedAssertions += 1
            print("  ❌ FAIL [line \(line)]: \(message) — expected \(expected), got \(actual)")
        }
    }
    
    static func runAllAndExit() async {
        print("========================================================")
        print("Starting PhotoboothApp2 Automated Verification (Tiers 2 & 3 + Lighting QA)")
        print("========================================================")
        
        runTier2Tests()
        do {
            try runLightingAndExposureQATests()
            try await runTier3Tests()
        } catch {
            failedAssertions += 1
            print("  ❌ FAIL: Unhandled error in verification suite: \(error)")
        }
        
        let summary = "Verification Summary: \(passedAssertions) PASSED, \(failedAssertions) FAILED"
        print("========================================================")
        print(summary)
        print("========================================================")
        fflush(stdout)
        exit(failedAssertions == 0 ? 0 : 1)
    }
    
    private static func runTier2Tests() {
        print("\n--- TIER 2: SonyPTPProtocol Binary Framing & Payload Parsers ---")
        
        // 1. Command Block Serialization
        let cmd = SonyPTPPacket.buildCommand(
            opcode: .sdioConnect,
            transactionID: 42,
            params: [1, 0, 0]
        )
        let expectedCmdBytes: [UInt8] = [
            24, 0, 0, 0,          // Length = 24
            1, 0,                 // Type = 0x0001 (Command Block)
            0x01, 0x92,           // Code = 0x9201 (SDIO_Connect)
            42, 0, 0, 0,          // TransactionID = 42
            1, 0, 0, 0,           // P1 = 1
            0, 0, 0, 0,           // P2 = 0
            0, 0, 0, 0            // P3 = 0
        ]
        assertEqual([UInt8](cmd), expectedCmdBytes, "Command block 24-byte Little-Endian layout")
        
        // 2. Little-Endian UInt16 & UInt8 Property Payload Serialization
        var data16 = Data()
        data16.appendLittleEndian(SonySaveDestination.pcAndCamera.rawValue)
        assertEqual([UInt8](data16), [0x11, 0x00], "UInt16 property payload Little-Endian layout (0x0011 -> 11 00)")
        
        var data8 = Data()
        data8.appendLittleEndian(SonyTransferImageSize.twoMegapixel.rawValue)
        assertEqual([UInt8](data8), [0x02], "UInt8 property payload layout (2M -> 02)")
        
        // 3. Response Block Serialization & Parsing
        let okResp = SonyPTPPacket.buildResponse(code: .ok, transactionID: 42)
        let busyResp = SonyPTPPacket.buildResponse(code: .deviceBusy, transactionID: 43)
        let shortResp = Data([1, 2, 3])
        assertEqual(SonyPTPPacket.parseResponseCode(from: okResp), 0x2001, "Parse PTP OK (0x2001)")
        assertEqual(SonyPTPPacket.parseResponseCode(from: busyResp), 0x2019, "Parse PTP Device Busy (0x2019)")
        assertEqual(SonyPTPPacket.parseResponseCode(from: shortResp), nil, "Reject truncated PTP response (< 8 bytes)")
        
        // 4. Live View Frame Extraction (0xFFFFC002)
        let syntheticJPEG = Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
            0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
            0xFF, 0xD9
        ])
        var paddedLVPayload = MockPTPTransport.buildMockLiveViewPayload(jpeg: syntheticJPEG, headerOffset: 8)
        paddedLVPayload.append(contentsOf: [0x00, 0x00, 0xAA, 0xBB]) // trailing padding bytes
        assertEqual(SonyPTPPacket.extractLiveViewJPEG(from: paddedLVPayload), syntheticJPEG, "Extract exact JPEG slice using 8-byte Sony Live View header")
        
        let fallbackLVPayload = MockPTPTransport.buildMockLiveViewPayload(jpeg: syntheticJPEG, headerOffset: 0xFFFF)
        assertEqual(SonyPTPPacket.extractLiveViewJPEG(from: fallbackLVPayload), syntheticJPEG, "Extract exact JPEG slice using SOI/EOI fallback scanner")
        
        let corruptedPayload = Data([0x08, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99])
        assertEqual(SonyPTPPacket.extractLiveViewJPEG(from: corruptedPayload), nil, "Reject corrupted/non-JPEG Live View buffer")
        
        // 5. ObjectInMemory (0xD215) Parser
        let ready8001 = MockPTPTransport.buildMockDeviceInfoPayload(objectInMemoryValue: 0x8001)
        let empty0000 = MockPTPTransport.buildMockDeviceInfoPayload(objectInMemoryValue: 0x0000)
        assertEqual(SonyPTPPacket.parseObjectInMemory(from: ready8001), 0x8001, "parseObjectInMemory extracts 0x8001 (>= 0x8000 ready)")
        assertEqual(SonyPTPPacket.parseObjectInMemory(from: empty0000), 0x0000, "parseObjectInMemory extracts 0x0000 (empty)")
    }
    
    private static func runTier3Tests() async throws {
        print("\n--- TIER 3: MockPTPTransport + StateMachine Timing & Concurrency ---")
        
        let transport = MockPTPTransport()
        let usbClient = SonyUSBCameraClient(injectedTransport: transport)
        
        // 1. 3-Phase Handshake Verification
        try await usbClient.connect()
        assertTrue(usbClient.isConnected, "SonyUSBCameraClient connects via MockPTPTransport")
        
        let handshakeOps = transport.commandLog.map { ($0.opcode, $0.parameters, $0.dataBytes) }
        assertTrue(handshakeOps.count >= 7, "Handshake executed at least 7 PTP commands (got \(handshakeOps.count))")
        assertEqual(handshakeOps[0].0, SonyPTPOpcode.sdioConnect.rawValue, "Step 1 is SDIO_Connect")
        assertEqual(handshakeOps[0].1, [1, 0, 0], "Step 1 PhaseType = 1")
        assertEqual(handshakeOps[1].0, SonyPTPOpcode.sdioConnect.rawValue, "Step 2 is SDIO_Connect")
        assertEqual(handshakeOps[1].1, [2, 0, 0], "Step 2 PhaseType = 2")
        assertEqual(handshakeOps[2].0, SonyPTPOpcode.sdioGetExtDeviceInfo.rawValue, "Step 3 is SDIO_GetExtDeviceInfo")
        assertEqual(handshakeOps[2].1.first, 0x012C, "Step 3 SDIExtensionVersion = 0x012C")
        assertEqual(handshakeOps[3].0, SonyPTPOpcode.sdioConnect.rawValue, "Step 4 is SDIO_Connect")
        assertEqual(handshakeOps[3].1, [3, 0, 0], "Step 4 PhaseType = 3")
        
        let set2M = handshakeOps.contains {
            $0.0 == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.1.first == UInt32(SonyPTPPropertyCode.pcSaveImageSize.rawValue) &&
            $0.2 == [0x02]
        }
        let setPCCamera = handshakeOps.contains {
            $0.0 == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.1.first == UInt32(SonyPTPPropertyCode.stillImageSaveDestination.rawValue) &&
            $0.2 == [0x11, 0x00]
        }
        let setLiveViewEffectOff = handshakeOps.contains {
            $0.0 == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.1.first == UInt32(SonyPTPPropertyCode.liveViewSettingEffect.rawValue) &&
            $0.2 == [0x02]
        }
        assertTrue(set2M, "Handshake sets 0xD268 (Transfer Size) = 2 (2M)")
        assertTrue(setPCCamera, "Handshake sets 0xD222 (Save Destination) = 0x0011 (PC + Camera)")
        assertTrue(setLiveViewEffectOff, "Handshake sets 0xD231 (Live View Setting Effect) = 2 (Setting Effect OFF)")
        
        // 2. Mode-Based Storage Routing Verification
        transport.resetLog()
        try await usbClient.prepareForCapture(mode: .standard)
        let stdSaveDest = transport.commandLog.contains {
            $0.opcode == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.stillImageSaveDestination.rawValue) &&
            $0.dataBytes == [0x11, 0x00]
        }
        assertTrue(stdSaveDest, "prepareForCapture(.standard) sets 0xD222 = 0x0011 (PC + Camera)")
        
        transport.resetLog()
        try await usbClient.prepareForCapture(mode: .gif)
        let gifSaveDest = transport.commandLog.contains {
            $0.opcode == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.stillImageSaveDestination.rawValue) &&
            $0.dataBytes == [0x01, 0x00]
        }
        assertTrue(gifSaveDest, "prepareForCapture(.gif) sets 0xD222 = 0x0001 (PC Only — bypasses SD card)")
        
        transport.resetLog()
        await usbClient.finishCaptureSequence(mode: .gif)
        let restoredSaveDest = transport.commandLog.contains {
            $0.opcode == SonyPTPOpcode.sdioSetExtDevicePropValue.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.stillImageSaveDestination.rawValue) &&
            $0.dataBytes == [0x11, 0x00]
        }
        assertTrue(restoredSaveDest, "finishCaptureSequence(.gif) restores 0xD222 = 0x0011 (PC + Camera)")
        
        // 3. Pre-Capture Buffer Drain + Strict Sequential S1/S2 Release + Zero Live View Interleaving
        transport.resetLog()
        transport.staleObjectInitiallyPresent = true
        transport.simulatedObjectInMemoryPollsBeforeReady = 2
        
        try await usbClient.startLiveView()
        try await Task.sleep(nanoseconds: 90_000_000)
        
        let urls = try await usbClient.takePicture()
        assertEqual(urls.count, 1, "takePicture() returns 1 local file:// URL")
        if let firstURLString = urls.first, let fileURL = URL(string: firstURLString) {
            assertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Captured JPEG file exists in /tmp")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        try await Task.sleep(nanoseconds: 90_000_000)
        usbClient.stopLiveView()
        
        let log = transport.commandLog
        let drainGetObjectIdx = log.firstIndex {
            $0.opcode == SonyPTPOpcode.getObject.rawValue &&
            $0.parameters.first == SonyPTPHostHandle.capturedImageRAM.rawValue
        }
        let s1DownIdx = log.firstIndex {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterHalfRelease.rawValue) &&
            $0.dataBytes == [0x02, 0x00]
        }
        let s2DownIdx = log.firstIndex {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterRelease.rawValue) &&
            $0.dataBytes == [0x02, 0x00]
        }
        let s2UpIdx = log.firstIndex {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterRelease.rawValue) &&
            $0.dataBytes == [0x01, 0x00]
        }
        let s1UpIdx = log.firstIndex {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterHalfRelease.rawValue) &&
            $0.dataBytes == [0x01, 0x00]
        }
        let captureGetObjectIdx = log.lastIndex {
            $0.opcode == SonyPTPOpcode.getObject.rawValue &&
            $0.parameters.first == SonyPTPHostHandle.capturedImageRAM.rawValue
        }
        
        if let drainIdx = drainGetObjectIdx, let s1D = s1DownIdx, let s2D = s2DownIdx, let s2U = s2UpIdx, let s1U = s1UpIdx, let capIdx = captureGetObjectIdx {
            assertTrue(drainIdx < s1D, "Stale 0xFFFFC001 object drained before S1 Down (\(drainIdx) < \(s1D))")
            assertTrue(s1D < s2D && s2D < s2U && s2U < s1U, "Strict sequential shutter ordering: S1 Down (\(s1D)) < S2 Down (\(s2D)) < S2 Up (\(s2U)) < S1 Up (\(s1U))")
            
            let midCaptureCommands = log[s1D...capIdx]
            let interleavedLiveViewCount = midCaptureCommands.filter {
                $0.opcode == SonyPTPOpcode.getObject.rawValue &&
                $0.parameters.first == SonyPTPHostHandle.liveViewFrameRAM.rawValue
            }.count
            assertEqual(interleavedLiveViewCount, 0, "Zero Live View (0xFFFFC002) commands interleaved between S1 Down and GetObject(0xFFFFC001)")
        } else {
            assertTrue(false, "Expected S1/S2/GetObject commands in log")
        }
        
        // 4. ConfigManager Min Time Between GIFs Clamping Verification
        let config = ConfigManager.shared
        config.resetToDefaults()
        assertEqual(config.gifCaptureInterval, 3.0, "Default Min Time Between GIFs is 3.0s")
        config.gifCaptureInterval = 0.2
        assertEqual(config.gifCaptureInterval, 0.5, "Min Time Between GIFs clamps values < 0.5s to 0.5s")
        
        // 5. Full StateMachine GIF Sequence Verification
        if let files = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("sony_") && f.pathExtension == "jpg" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        
        transport.resetLog()
        transport.staleObjectInitiallyPresent = false
        transport.simulatedObjectInMemoryPollsBeforeReady = 1
        
        config.useLocalCamera = false
        config.initialCountdownSec = 1
        config.showGuidanceText = false
        config.gifFrameCount = 4
        config.gifCaptureInterval = 0.6
        config.gifPreviewDuration = 1.0
        config.saveToPhotos = false
        config.enableImageSharing = true
        
        let sm = StateMachine(cameraService: usbClient)
        sm.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        assertEqual(sm.state, .idle, "StateMachine transitions to .idle once USB camera is connected")
        
        var observedPoses: [(String, Bool, Date)] = []
        var cancellables = Set<AnyCancellable>()
        sm.$poseIndicator
            .compactMap { $0 }
            .sink { pose in
                observedPoses.append((pose, sm.isFlashing, Date()))
            }
            .store(in: &cancellables)
        
        let triggerTime = Date()
        sm.triggerCapture(mode: .gif)
        
        var enteredReview = false
        var reviewImages: [String] = []
        for _ in 0..<80 {
            if case .review(let imgs, _) = sm.state {
                enteredReview = true
                reviewImages = imgs
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assertTrue(enteredReview, "StateMachine completed 4-frame GIF capture and entered .review")
        assertEqual(reviewImages.count, 1, "GIF Mode passes ONLY the single compiled .gif to ReviewView (count == 1)")
        if let gifURLStr = reviewImages.first {
            assertTrue(gifURLStr.hasSuffix(".gif"), "Review image URL is a .gif file")
        }
        
        let remainingSonyJPGs = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil))?.filter {
            $0.lastPathComponent.hasPrefix("sony_") && $0.pathExtension == "jpg"
        } ?? []
        assertEqual(remainingSonyJPGs.count, 0, "All 4 temporary sony_*.jpg source frames were immediately deleted after GIF creation")
        
        let s2DownEvents = transport.commandLog.filter {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterRelease.rawValue) &&
            $0.dataBytes == [0x02, 0x00]
        }
        assertEqual(s2DownEvents.count, 4, "4 shutter releases recorded in GIF sequence")
        if s2DownEvents.count == 4 {
            let frame1Delay = s2DownEvents[0].timestamp.timeIntervalSince(triggerTime)
            assertTrue(frame1Delay < 1.35, "Frame 1 triggered immediately after 1.0s countdown without legacy 0.5s delay (elapsed: \(String(format: "%.2f", frame1Delay))s)")
            
            for i in 0..<3 {
                let delta = s2DownEvents[i + 1].timestamp.timeIntervalSince(s2DownEvents[i].timestamp)
                assertTrue(delta >= 0.55, "Frame \(i + 1) -> Frame \(i + 2) total interval respected Min Time Between GIFs (0.6s): \(String(format: "%.2f", delta))s")
            }
        }
        
        let poseNames = observedPoses.map { $0.0 }
        assertEqual(poseNames, ["Second Pose", "Third Pose", "Fourth Pose"], "Observed exact pose prompt sequence: Second Pose, Third Pose, Fourth Pose")
        
        // Test 2.0s default interval specifically for Flash vs "Second Pose" non-overlap
        transport.resetLog()
        observedPoses.removeAll()
        config.gifCaptureInterval = 2.0
        config.gifFrameCount = 2
        sm.skipSharing()
        try await Task.sleep(nanoseconds: 100_000_000)
        sm.triggerCapture(mode: .gif)
        for _ in 0..<60 {
            if case .review = sm.state { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let secondPoseEvent = observedPoses.first(where: { $0.0 == "Second Pose" }) {
            assertTrue(!secondPoseEvent.1, "Frame 1 white screen flash (0.45s) is already FALSE when 'Second Pose' appears at 2.0s default interval")
        } else {
            assertTrue(false, "Expected 'Second Pose' event during 2.0s interval test")
        }
        
        // 6. 1.5s USB Disconnect Debounce + Auto-Recovery Verification
        sm.skipSharing()
        try await Task.sleep(nanoseconds: 100_000_000)
        assertEqual(sm.state, .idle, "StateMachine is in .idle before disconnect test")
        
        // Transient 200ms glitch (< 1.5s debounce)
        usbClient.isConnected = false
        try await Task.sleep(nanoseconds: 200_000_000)
        usbClient.isConnected = true
        try await Task.sleep(nanoseconds: 200_000_000)
        assertEqual(sm.state, .idle, "Transient 200ms USB glitch was debounced; StateMachine stayed in .idle")
        
        // Sustained > 1.5s disconnect
        usbClient.isConnected = false
        try await Task.sleep(nanoseconds: 1_700_000_000)
        if case .error = sm.state {
            assertTrue(true, "Sustained >1.5s USB disconnect transitioned StateMachine to .error")
        } else {
            assertTrue(false, "Expected .error state after >1.5s disconnect, got \(sm.state)")
        }
        
        // Reconnect recovery -> should automatically return to .idle
        usbClient.isConnected = true
        try await Task.sleep(nanoseconds: 200_000_000)
        assertEqual(sm.state, .idle, "Reconnecting USB cable automatically recovered StateMachine from .error to .idle")
        
        // 7. Standard Photo Capture Sequence + Preloaded Review Image + Sharing Flow
        transport.resetLog()
        config.photoCount = 2
        config.initialCountdownSec = 1
        config.interShotCountdownSec = 1
        config.previewDurationSec = 1
        config.showGuidanceText = false
        config.saveToPhotos = false
        config.enableImageSharing = true
        
        sm.triggerCapture(mode: .standard)
        var enteredStandardReview = false
        var stdReviewImages: [String] = []
        for _ in 0..<80 {
            if case .review(let imgs, _) = sm.state {
                enteredStandardReview = true
                stdReviewImages = imgs
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assertTrue(enteredStandardReview, "Standard Mode completed 2-photo capture sequence and entered .review")
        assertEqual(stdReviewImages.count, 2, "Standard Mode passes 2 captured JPEG URLs to ReviewView")
        assertTrue(sm.currentReviewImage != nil, "Standard Mode pre-loads currentReviewImage before review display (zero spinner flicker)")
        
        // Wait for 2-photo review (2 * 1.0s) to transition to .sharingPrompt, then selectAirDrop()
        var enteredSharingPrompt = false
        for _ in 0..<40 {
            if case .sharingPrompt = sm.state {
                enteredSharingPrompt = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        assertTrue(enteredSharingPrompt, "Standard Mode transitions from .review to .sharingPrompt")
        sm.selectAirDrop()
        if case .airDrop(let airDropImgs) = sm.state {
            assertEqual(airDropImgs.count, 2, "selectAirDrop() transitions to .airDrop with 2 photos")
            for urlStr in airDropImgs {
                if let u = URL(string: urlStr) {
                    assertTrue(FileManager.default.fileExists(atPath: u.path), "2MP still image exists in /tmp during AirDrop")
                }
            }
        } else {
            assertTrue(false, "Expected .airDrop state after selectAirDrop()")
        }
        
        // 8. Immediate 2MP Still Image Deletion + Race-Free /tmp Cleanup (>10m deleted, <10m preserved)
        let tempDir = FileManager.default.temporaryDirectory
        let oldTempFile = tempDir.appendingPathComponent("old_orphan_\(UUID().uuidString).jpg")
        let freshTempFile = tempDir.appendingPathComponent("fresh_active_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: oldTempFile)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: freshTempFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-900)], // 15 minutes old (> 10m threshold)
            ofItemAtPath: oldTempFile.path
        )
        
        sm.skipSharing() // Transitions to .idle, immediately deleting the session's 2MP still images
        try await Task.sleep(nanoseconds: 150_000_000)
        for urlStr in stdReviewImages {
            if let u = URL(string: urlStr) {
                assertTrue(!FileManager.default.fileExists(atPath: u.path), "2MP still image was immediately deleted from iPad after review/AirDrop finished")
            }
        }
        assertTrue(!FileManager.default.fileExists(atPath: oldTempFile.path), "Orphaned /tmp file older than 10 minutes (15m) was purged on return to .idle")
        assertTrue(FileManager.default.fileExists(atPath: freshTempFile.path), "Recent /tmp file (< 10 minutes old) was preserved for background Photo Library / AirDrop")
        try? FileManager.default.removeItem(at: freshTempFile)
        
        // 9. App Switching Lifecycle (handleAppDidEnterBackground / handleAppDidBecomeActive)
        sm.handleAppDidEnterBackground()
        try await Task.sleep(nanoseconds: 50_000_000)
        sm.handleAppDidBecomeActive()
        try await Task.sleep(nanoseconds: 100_000_000)
        assertEqual(sm.state, .idle, "App background -> foreground transition preserves .idle state and resumes USB session cleanly")
        
        // 10. GIFService file:// URL Aspect Ratio & Resolution Scaling Verification
        let frame1URL = tempDir.appendingPathComponent("gif_test_1_\(UUID().uuidString).jpg")
        let frame2URL = tempDir.appendingPathComponent("gif_test_2_\(UUID().uuidString).jpg")
        try transport.sampleJPEGData.write(to: frame1URL)
        try transport.sampleJPEGData.write(to: frame2URL)
        if let gifURL = GIFService.createGIF(from: [frame1URL.absoluteString, frame2URL.path], frameDuration: 0.25, resolution: 0) {
            assertTrue(FileManager.default.fileExists(atPath: gifURL.path), "GIFService.createGIF handles mixed file:// URLs and POSIX paths")
            try? FileManager.default.removeItem(at: gifURL)
        } else {
            assertTrue(false, "GIFService.createGIF failed on valid JPEG inputs")
        }
        try? FileManager.default.removeItem(at: frame1URL)
        try? FileManager.default.removeItem(at: frame2URL)
        
        config.resetToDefaults()
    }
    
    // MARK: - Simulated Lighting & Exposure Scaling QA Suite
    
    /// Synthesizes a 48x48 sRGB test image with configurable background RGB, center subject RGB,
    /// bottom-right secondary patch RGB, top-left shadow ramp (`1, 2, 4, 8, 16`), and optional specular lamp.
    private static func makeSyntheticLightingScene(
        bgRGB: (UInt8, UInt8, UInt8),
        subjectSkinRGB: (UInt8, UInt8, UInt8),
        shirtRGB: (UInt8, UInt8, UInt8),
        includeShadowRamp: Bool = false,
        includeSmallBrightLamp: Bool = false
    ) -> CGImage {
        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        
        for y in 0..<height {
            for x in 0..<width {
                var rgb = bgRGB
                // Center subject skin patch (x: 12..<30, y: 12..<30)
                if x >= 12 && x < 30 && y >= 12 && y < 30 {
                    rgb = subjectSkinRGB
                }
                // Shirt patch (x: 12..<36, y: 30..<38)
                else if x >= 12 && x < 36 && y >= 30 && y < 38 {
                    rgb = shirtRGB
                }
                // Optional shadow step ramp at y == 4, x == 2, 4, 6, 8, 10
                if includeShadowRamp && y == 4 {
                    if x == 2 { rgb = (1, 1, 1) }
                    else if x == 4 { rgb = (2, 2, 2) }
                    else if x == 6 { rgb = (4, 4, 4) }
                    else if x == 8 { rgb = (8, 8, 8) }
                    else if x == 10 { rgb = (16, 16, 16) }
                }
                // Optional small specular background lamp (< 2% of pixels)
                if includeSmallBrightLamp && x >= 42 && x < 45 && y >= 3 && y < 6 {
                    rgb = (245, 240, 225)
                }
                
                let idx = (y * width + x) * 4
                pixels[idx] = rgb.0
                pixels[idx + 1] = rgb.1
                pixels[idx + 2] = rgb.2
                pixels[idx + 3] = 255
            }
        }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
    
    /// Reads the exact `(R, G, B)` 8-bit tuple at `(x, y)` from a `CGImage`.
    private static func readPixelRGB(_ cgImage: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0, 0)
        }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let idx = (y * width + x) * 4
        return (Int(pixels[idx]), Int(pixels[idx + 1]), Int(pixels[idx + 2]))
    }
    
    private static func runLightingAndExposureQATests() throws {
        print("\n--- LIGHTING & EXPOSURE SCALING QA SUITE ---")
        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let tempDir = FileManager.default.temporaryDirectory
        
        // 1. Low-Light Mode "1" / Manual ISO 200 without Flash
        //    Dark background (2,2,3), warm skin (18,12,8), cool blue shirt (7,13,20), shadow ramp, and small lamp.
        let lowLightCG = makeSyntheticLightingScene(
            bgRGB: (2, 2, 3),
            subjectSkinRGB: (18, 12, 8),
            shirtRGB: (7, 13, 20),
            includeShadowRamp: true,
            includeSmallBrightLamp: true
        )
        let (lowPreLuma, _) = SonyUSBCameraClient.measureSceneLuminance(lowLightCG)
        let lowBoostedCG = SonyUSBCameraClient.autoExposeCapturedCGImage(lowLightCG, ciContext: ciContext)
        let (lowPostLuma, lowPostP90) = SonyUSBCameraClient.measureSceneLuminance(lowBoostedCG)
        
        assertTrue(
            lowPreLuma < 0.04 && lowPostLuma >= 0.25 && lowPostLuma <= 0.52,
            String(format: "Low-Light Mode 1 brightness recovery: %.3f -> %.3f sRGB (target 0.25..0.52)", lowPreLuma, lowPostLuma)
        )
        assertTrue(
            lowPostP90 < 0.85,
            String(format: "Low-Light Mode 1 90th-percentile highlight stays un-clipped: p90=%.3f (< 0.85)", lowPostP90)
        )
        
        // Verify RGB color ordering & chroma preservation (NOT black-and-white!)
        let skinPost = readPixelRGB(lowBoostedCG, x: 20, y: 20)
        let shirtPost = readPixelRGB(lowBoostedCG, x: 20, y: 34)
        assertTrue(
            skinPost.r > skinPost.g && skinPost.g > skinPost.b && (skinPost.r - skinPost.b) >= 15 && skinPost.r < 235,
            "Low-Light Mode 1 preserves warm skin color ratios (R=\(skinPost.r) > G=\(skinPost.g) > B=\(skinPost.b), non-clipped)"
        )
        assertTrue(
            shirtPost.b > shirtPost.g && shirtPost.g > shirtPost.r && (shirtPost.b - shirtPost.r) >= 12 && shirtPost.b < 235,
            "Low-Light Mode 1 preserves cool shirt color ratios (B=\(shirtPost.b) > G=\(shirtPost.g) > R=\(shirtPost.r), non-clipped)"
        )
        
        // Verify smooth shadow gradation (no 1-bit block quantization where 1/255 jumps to 255)
        let step1 = readPixelRGB(lowBoostedCG, x: 2, y: 4).r
        let step2 = readPixelRGB(lowBoostedCG, x: 4, y: 4).r
        let step4 = readPixelRGB(lowBoostedCG, x: 6, y: 4).r
        let step8 = readPixelRGB(lowBoostedCG, x: 8, y: 4).r
        let step16 = readPixelRGB(lowBoostedCG, x: 10, y: 4).r
        assertTrue(
            step1 < step4 && step4 < step8 && step8 < step16 && step1 < 80 && step16 < 210,
            "Low-Light Mode 1 shadow steps (1,2,4,8,16/255) scale smoothly without 1-bit block clipping: [\(step1), \(step2), \(step4), \(step8), \(step16)]"
        )
        
        // 2. Decent Light / Dim Auto-ISO 12800 ("A little dim on camera, but viewable")
        //    Warm room walls (62,55,48), viewable face/forehead (155,136,120) -> preLuma ~0.31, p90 ~0.55.
        let autoISOCG = makeSyntheticLightingScene(
            bgRGB: (62, 55, 48),
            subjectSkinRGB: (155, 136, 120),
            shirtRGB: (80, 95, 115)
        )
        let (autoPreLuma, autoPreP90) = SonyUSBCameraClient.measureSceneLuminance(autoISOCG)
        let autoBoostedCG = SonyUSBCameraClient.autoExposeCapturedCGImage(autoISOCG, ciContext: ciContext)
        let (autoPostLuma, autoPostP90) = SonyUSBCameraClient.measureSceneLuminance(autoBoostedCG)
        let autoFacePost = readPixelRGB(autoBoostedCG, x: 20, y: 20)
        
        assertTrue(
            autoPostLuma > autoPreLuma && autoPostLuma <= 0.45,
            String(format: "Auto-ISO 12800 dim capture receives gentle midtone lift: %.3f -> %.3f sRGB", autoPreLuma, autoPostLuma)
        )
        assertTrue(
            autoPostP90 < 0.82 && autoFacePost.r < 220 && autoFacePost.r > autoFacePost.g && autoFacePost.g > autoFacePost.b,
            String(format: "Auto-ISO 12800 highlights are protected from blowing out: p90 %.3f -> %.3f, face RGB=(%d,%d,%d)", autoPreP90, autoPostP90, autoFacePost.r, autoFacePost.g, autoFacePost.b)
        )
        
        // 3. Threshold Continuity Check (0.36 -> 0.44 sRGB)
        //    Ensures no step jump near the 0.42 trigger threshold.
        var prevOutLuma: Double? = nil
        var maxStepDelta: Double = 0.0
        for rawVal in stride(from: 92, through: 114, by: 4) { // ~0.36 to ~0.45 sRGB
            let v = UInt8(rawVal)
            let testCG = makeSyntheticLightingScene(bgRGB: (v, v, v), subjectSkinRGB: (v, v, v), shirtRGB: (v, v, v))
            let outCG = SonyUSBCameraClient.autoExposeCapturedCGImage(testCG, ciContext: ciContext)
            let (outLuma, _) = SonyUSBCameraClient.measureSceneLuminance(outCG)
            if let prev = prevOutLuma {
                maxStepDelta = max(maxStepDelta, abs(outLuma - prev))
            }
            prevOutLuma = outLuma
        }
        assertTrue(
            maxStepDelta < 0.030,
            String(format: "Exposure curve across 0.36..0.45 sRGB threshold is smooth with zero step jump (maxStepDelta=%.4f)", maxStepDelta)
        )
        
        // 4. 4-Frame GIF Burst Equalization (Simulating 4th-Frame Overexposure in Aperture Priority)
        //    Frames 1-3 at ~0.41 sRGB (105,105,105), Frame 4 drifted brighter to ~0.52 sRGB (133,133,133).
        var burstURLs: [URL] = []
        let frameValues: [UInt8] = [104, 106, 105, 134]
        for (idx, val) in frameValues.enumerated() {
            let cg = makeSyntheticLightingScene(
                bgRGB: (val, val, val),
                subjectSkinRGB: (val &+ 10, val, val &- 8),
                shirtRGB: (val &- 10, val, val &+ 8)
            )
            let ui = UIImage(cgImage: cg)
            let fileURL = tempDir.appendingPathComponent("sony_qa_burst_\(idx)_\(UUID().uuidString).jpg")
            try ui.jpegData(compressionQuality: 0.92)!.write(to: fileURL)
            burstURLs.append(fileURL)
        }
        
        if let compiledGIFURL = GIFService.createGIF(from: burstURLs.map(\.absoluteString), frameDuration: 0.25) {
            if let gifSource = CGImageSourceCreateWithURL(compiledGIFURL as CFURL, nil) {
                let count = CGImageSourceGetCount(gifSource)
                assertEqual(count, 4, "Compiled burst GIF contains 4 frames")
                var outputFrameLumas: [Double] = []
                for i in 0..<count {
                    if let frameCG = CGImageSourceCreateImageAtIndex(gifSource, i, nil) {
                        outputFrameLumas.append(SonyUSBCameraClient.measureSceneLuminance(frameCG).subjectSrgbY)
                    }
                }
                if let minL = outputFrameLumas.min(), let maxL = outputFrameLumas.max() {
                    let spread = maxL - minL
                    assertTrue(
                        spread < 0.030,
                        String(format: "GIFService equalizes 4th-frame exposure drift (input spread 0.115 -> output spread %.4f)", spread)
                    )
                }
            }
            
            // Verify GIFPlayerView.loadAnimatedImage decodes the 4-frame GIF synchronously for instant in-app preview
            let startDecode = Date()
            let animatedImage = GIFPlayerView.loadAnimatedImage(from: compiledGIFURL)
            let decodeMs = Date().timeIntervalSince(startDecode) * 1000.0
            assertTrue(
                animatedImage != nil && (animatedImage?.images?.count == 4),
                String(format: "GIFPlayerView.loadAnimatedImage decodes 4-frame animated UIImage in %.1fms (no black WKWebView delay)", decodeMs)
            )
            try? FileManager.default.removeItem(at: compiledGIFURL)
        } else {
            assertTrue(false, "Failed to create burst QA GIF")
        }
        for u in burstURLs { try? FileManager.default.removeItem(at: u) }
        
        // 5. Non-Duplication Verification for Low-Light Sony Captures in GIFService
        //    Verify that a `sony_<UUID>.jpg` file that was already auto-exposed once during capture
        //    is NOT auto-exposed a second time inside GIFService.createGIF.
        let singleExposedLowUI = UIImage(cgImage: lowBoostedCG)
        let sonyLowURL = tempDir.appendingPathComponent("sony_lowlight_once_\(UUID().uuidString).jpg")
        try singleExposedLowUI.jpegData(compressionQuality: 0.92)!.write(to: sonyLowURL)
        if let lowGIFURL = GIFService.createGIF(from: [sonyLowURL.absoluteString, sonyLowURL.absoluteString], frameDuration: 0.25),
           let src = CGImageSourceCreateWithURL(lowGIFURL as CFURL, nil),
           let gifFrameCG = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let (gifFrameLuma, _) = SonyUSBCameraClient.measureSceneLuminance(gifFrameCG)
            assertTrue(
                abs(gifFrameLuma - lowPostLuma) < 0.035,
                String(format: "Low-light sony_*.jpg is NOT double-exposed in GIFService (singlePass=%.3f vs gifFrame=%.3f)", lowPostLuma, gifFrameLuma)
            )
            try? FileManager.default.removeItem(at: lowGIFURL)
        } else {
            assertTrue(false, "Failed to verify low-light GIF non-duplication")
        }
        try? FileManager.default.removeItem(at: sonyLowURL)
    }
}
#endif

