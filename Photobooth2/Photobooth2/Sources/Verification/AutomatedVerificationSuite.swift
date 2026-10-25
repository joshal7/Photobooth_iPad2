#if DEBUG
import Foundation
import Combine
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

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
        print("Starting PhotoboothApp2 Automated Verification (Tiers 2 & 3 + Lighting + Email Queue QA)")
        print("========================================================")
        
        runTier2Tests()
        do {
            try runLightingAndExposureQATests()
            try await runTier3Tests()
            try await runEmailSharingAndQueueQATests()
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
        var observedDotIndices: [Int] = []
        var vignetteFlashCount: Int = 0
        var cancellables = Set<AnyCancellable>()
        sm.$poseIndicator
            .compactMap { $0 }
            .sink { pose in
                observedPoses.append((pose, sm.isFlashing, Date()))
            }
            .store(in: &cancellables)
        sm.$currentGIFFrameIndex
            .removeDuplicates()
            .filter { $0 > 0 }
            .sink { idx in
                observedDotIndices.append(idx)
            }
            .store(in: &cancellables)
        sm.$isVignetteFlashing
            .removeDuplicates()
            .filter { $0 }
            .sink { _ in
                vignetteFlashCount += 1
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
        
        assertEqual(observedDotIndices, [1, 2, 3, 4, 5], "Top-center progress dots highlighted Frame 1 through Frame 4 and completed all 4 dots (5)")
        assertEqual(vignetteFlashCount, 4, "0.2s perimeter vignette flash fired on all 4 GIF frames")
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
        
        sm.skipSharing() // Transitions from .airDrop to .idle (90s sharingd retention grace window)
        try await Task.sleep(nanoseconds: 150_000_000)
        for urlStr in stdReviewImages {
            if let u = URL(string: urlStr) {
                assertTrue(FileManager.default.fileExists(atPath: u.path), "2MP still image is preserved during 90s sharingd background transfer window after .airDrop -> .idle")
            }
        }
        sm.cleanupTempFiles(stdReviewImages)
        for urlStr in stdReviewImages {
            if let u = URL(string: urlStr) {
                assertTrue(!FileManager.default.fileExists(atPath: u.path), "cleanupTempFiles removes 2MP still image from /tmp")
            }
        }
        
        // Also verify immediate deletion when skipping directly from .sharingPrompt -> .idle
        let directSkipTempFile = tempDir.appendingPathComponent("direct_skip_\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: directSkipTempFile)
        sm.capturedImages = [directSkipTempFile.absoluteString]
        sm.transition(to: .sharingPrompt(images: [directSkipTempFile.absoluteString]))
        sm.skipSharing()
        try await Task.sleep(nanoseconds: 50_000_000)
        assertTrue(!FileManager.default.fileExists(atPath: directSkipTempFile.path), "2MP still image is immediately deleted when skipping directly from .sharingPrompt -> .idle")
        
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
        
        // 11. Persistent Background Selection Setting (Defaults to Off, Persists When On, Reverts When Toggled Off)
        config.resetToDefaults()
        assertEqual(config.persistentBackdropSelection, false, "persistentBackdropSelection defaults to false (off)")
        assertEqual(sm.selectedBackdrop.id, BackdropItem.noneID, "Default selected backdrop is live camera (.none)")
        
        let nonNoneBackdrops = BackdropManager.shared.enabledBackdrops.filter { !$0.isNone }
        if let firstTheme = nonNoneBackdrops.first {
            // 11a. With persistentBackdropSelection == false, returning to .idle resets to default (.none)
            sm.selectBackdrop(firstTheme)
            assertEqual(sm.selectedBackdrop.id, firstTheme.id, "Guest selects backdrop (\(firstTheme.displayName))")
            sm.transition(to: .idle)
            assertEqual(sm.selectedBackdrop.id, BackdropItem.noneID, "With persistentBackdropSelection off, next photo resets to default live background")
            
            // 11b. With persistentBackdropSelection == true, returning to .idle keeps the selected backdrop
            config.persistentBackdropSelection = true
            sm.selectBackdrop(firstTheme)
            sm.transition(to: .idle)
            assertEqual(sm.selectedBackdrop.id, firstTheme.id, "With persistentBackdropSelection on, selected backdrop (\(firstTheme.displayName)) stays present for the next photo")
            
            // 11c. Selecting a different backdrop updates and persists the new backdrop
            if let secondTheme = nonNoneBackdrops.dropFirst().first {
                sm.selectBackdrop(secondTheme)
                sm.transition(to: .idle)
                assertEqual(sm.selectedBackdrop.id, secondTheme.id, "Selecting a different backdrop (\(secondTheme.displayName)) persists that new backdrop for the next photo")
            }
            
            // 11d. Toggling persistentBackdropSelection off immediately reverts to the default background
            config.persistentBackdropSelection = false
            assertEqual(sm.selectedBackdrop.id, BackdropItem.noneID, "Toggling persistentBackdropSelection off immediately reverts to default background")
        }
        
        // 12. Superseded State Task Cancellation & Custom Backdrop Symbol-Only Name Fallback
        transport.resetLog()
        config.initialCountdownSec = 2
        sm.triggerCapture(mode: .standard)
        try await Task.sleep(nanoseconds: 150_000_000)
        // Cancel mid-countdown by transitioning back to .idle
        sm.transition(to: .idle)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        assertEqual(sm.state, .idle, "Cancelled capture sequence task does not mutate StateMachine state after transition to .idle")
        let postCancelShutters = transport.commandLog.filter {
            $0.opcode == SonyPTPOpcode.sdioControlDevice.rawValue &&
            $0.parameters.first == UInt32(SonyPTPPropertyCode.shutterRelease.rawValue)
        }
        assertEqual(postCancelShutters.count, 0, "Cancelled capture sequence task fires zero shutter commands")
        
        if let customItem = BackdropManager.shared.addCustomBackdrop(
            displayName: "!!!",
            backgroundData: transport.sampleJPEGData,
            foregroundPNGData: nil
        ) {
            assertTrue(!customItem.id.isEmpty && customItem.id != BackdropItem.noneID && !customItem.isNone, "Custom backdrop with symbol-only name receives valid non-none ID (\(customItem.id))")
            BackdropManager.shared.deleteCustomBackdrop(id: customItem.id)
        } else {
            assertTrue(false, "Expected addCustomBackdrop to succeed with valid backgroundData")
        }
        
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
        let width = 72
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
            lowPreLuma < 0.04 && lowPostLuma >= 0.08 && lowPostLuma <= 0.45 && lowPostP90 >= 0.18 && lowPostP90 < 0.85,
            String(format: "Low-Light Mode 1 brightness recovery with linear toe slope: mean %.3f -> %.3f, subject p90=%.3f (0.18..0.85)", lowPreLuma, lowPostLuma, lowPostP90)
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
        
        // Verify smooth shadow gradation (no 46x toe cliff where 1/255 jumps to 45+)
        let step1 = readPixelRGB(lowBoostedCG, x: 2, y: 4).r
        let step2 = readPixelRGB(lowBoostedCG, x: 4, y: 4).r
        let step4 = readPixelRGB(lowBoostedCG, x: 6, y: 4).r
        let step8 = readPixelRGB(lowBoostedCG, x: 8, y: 4).r
        let step16 = readPixelRGB(lowBoostedCG, x: 10, y: 4).r
        assertTrue(
            step1 <= 12 && step1 < step2 && step2 < step4 && step4 < step8 && step8 < step16 && step16 < 180,
            "Low-Light Mode 1 shadow steps (1,2,4,8,16/255) scale smoothly with linear toe slope (step1 <= 12): [\(step1), \(step2), \(step4), \(step8), \(step16)]"
        )
        
        // 2. Decent Light / Dim Auto-ISO 12800 ("A little dim on camera, but viewable")
        //    Warm room walls (62,55,48), viewable face/forehead (155,136,120) -> preLuma ~0.25, p90 ~0.37.
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
        
        // 3. Threshold Continuity Check (0.34 -> 0.44 sRGB)
        //    Ensures no step jump near the 0.38 trigger threshold.
        var prevOutLuma: Double? = nil
        var maxStepDelta: Double = 0.0
        for rawVal in stride(from: 88, through: 112, by: 4) { // ~0.34 to ~0.44 sRGB
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
            String(format: "Exposure curve across 0.34..0.44 sRGB threshold is smooth with zero step jump (maxStepDelta=%.4f)", maxStepDelta)
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
        
        // 6. 16x16 4:2:0 JPEG Macroblock Discretization & Zero-Halo Verification
        //    Synthesize a camera-resolution (320x240) low-light beige wall & maroon shirt scene where
        //    adjacent 16x16 blocks toggle weak channels between 0, 1, and 2 LSBs, and verify:
        //    (a) adjacent blocks do not jump by 45+ levels (maxJump <= 10 vs old 59), and
        //    (b) the maroon shirt does NOT bleed red chroma halos onto the adjacent beige wall.
        let deblockW = 320, deblockH = 240
        var deblockPixels = [UInt8](repeating: 255, count: deblockW * deblockH * 4)
        for y in 0..<deblockH {
            for x in 0..<deblockW {
                let bx = (x / 16) % 3
                let idx = (y * deblockW + x) * 4
                if y < 120 {
                    // Low-light warm wall where B toggles 0, 1, 2 across 16x16 macroblocks
                    deblockPixels[idx]     = 8
                    deblockPixels[idx + 1] = 4
                    deblockPixels[idx + 2] = UInt8(bx) // 0, 1, 2
                } else if x >= 90 && x < 230 {
                    // Dark maroon shirt in center bottom
                    deblockPixels[idx]     = 72
                    deblockPixels[idx + 1] = 16
                    deblockPixels[idx + 2] = 18
                } else {
                    // Neutral beige wall next to maroon shirt
                    deblockPixels[idx]     = 110
                    deblockPixels[idx + 1] = 102
                    deblockPixels[idx + 2] = 86
                }
            }
        }
        let deblockCS = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let deblockCtx = CGContext(
            data: &deblockPixels,
            width: deblockW,
            height: deblockH,
            bitsPerComponent: 8,
            bytesPerRow: deblockW * 4,
            space: deblockCS,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let rawBlockyCG = deblockCtx.makeImage() {
            let deblockedCG = SonyUSBCameraClient.autoExposeCapturedCGImage(rawBlockyCG, ciContext: ciContext)
            let b0 = readPixelRGB(deblockedCG, x: 8, y: 60)   // Center of block 0 (raw B=0)
            let b1 = readPixelRGB(deblockedCG, x: 24, y: 60)  // Center of block 1 (raw B=1)
            let b2 = readPixelRGB(deblockedCG, x: 40, y: 60)  // Center of block 2 (raw B=2)
            let maxBlueBlockJump = max(abs(b0.b - b1.b), abs(b1.b - b2.b))
            assertTrue(
                maxBlueBlockJump <= 10,
                "Low-light 16x16 macroblock linear toe prevents 45-level shadow cliff (B=\(b0.b),\(b1.b),\(b2.b), maxJump=\(maxBlueBlockJump) <= 10 vs old 59)"
            )
            // Verify zero pink/red halo bleeding from maroon shirt (x=90..230) onto adjacent beige wall (x=82 vs x=20)
            let wallNearShirt = readPixelRGB(deblockedCG, x: 82, y: 180)
            let wallFarFromShirt = readPixelRGB(deblockedCG, x: 20, y: 180)
            let redGreenDiffNear = wallNearShirt.r - wallNearShirt.g
            let redGreenDiffFar = wallFarFromShirt.r - wallFarFromShirt.g
            assertTrue(
                abs(redGreenDiffNear - redGreenDiffFar) <= 2,
                "Zero red chroma halo bleeding from maroon shirt onto adjacent beige wall (near R-G=\(redGreenDiffNear) vs far R-G=\(redGreenDiffFar))"
            )
        }
        
        // 7. Very-Low-Light (0..2/255 Monochrome Still Capture) Hardware Live View Frame Recovery
        //    When the camera's 0xFFFFC001 still capture is crushed into 0..2/255 monochrome (e.g. strobe settings without flash),
        //    normalizeAndAutoExposeCapturedJPEG recovers the hardware-exposed 0xFFFFC002 Live View frame.
        let crushedStillCG = makeSyntheticLightingScene(
            bgRGB: (1, 1, 1),
            subjectSkinRGB: (2, 2, 2),
            shirtRGB: (1, 1, 1)
        )
        let hardwareLiveViewCG = makeSyntheticLightingScene(
            bgRGB: (28, 25, 22),
            subjectSkinRGB: (110, 78, 56),
            shirtRGB: (42, 82, 130)
        )
        if let crushedData = UIImage(cgImage: crushedStillCG).jpegData(compressionQuality: 0.90),
           let liveViewData = UIImage(cgImage: hardwareLiveViewCG).jpegData(compressionQuality: 0.90) {
            let recoveredData = SonyUSBCameraClient.normalizeAndAutoExposeCapturedJPEG(
                crushedData,
                backdrop: .none,
                captureMode: .standard,
                fallbackLiveViewJPEG: liveViewData
            )
            if let recoveredCG = UIImage(data: recoveredData)?.cgImage {
                // Note: normalizeAndAutoExposeCapturedJPEG horizontally mirrors the 72x48 image, so x=20 mirrors to x=51
                let recSkin = readPixelRGB(recoveredCG, x: 51, y: 20)
                let recShirt = readPixelRGB(recoveredCG, x: 51, y: 34)
                assertTrue(
                    recSkin.r > recSkin.g && recSkin.g > recSkin.b && (recSkin.r - recSkin.b) >= 18 &&
                    recShirt.b > recShirt.g && recShirt.g > recShirt.r && (recShirt.b - recShirt.r) >= 18,
                    "Very-low-light hardware Live View recovery restores full skin (\(recSkin.r),\(recSkin.g),\(recSkin.b)) & shirt (\(recShirt.r),\(recShirt.g),\(recShirt.b)) color from 0xFFFFC002"
                )
            } else {
                assertTrue(false, "Failed to decode recovered very-low-light JPEG")
            }
        }
        
        // 8. Full 2MP (1620x1080) GPU Exposure Timing Benchmark (< 35ms in Debug build)
        let benchW = 1620, benchH = 1080
        var benchPixels = [UInt8](repeating: 42, count: benchW * benchH * 4)
        if let benchCtx = CGContext(
            data: &benchPixels,
            width: benchW,
            height: benchH,
            bitsPerComponent: 8,
            bytesPerRow: benchW * 4,
            space: deblockCS,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let benchCG = benchCtx.makeImage() {
            // Warm up Metal pipeline once
            _ = SonyUSBCameraClient.autoExposeCapturedCGImage(benchCG, ciContext: ciContext)
            let startBench = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 {
                _ = SonyUSBCameraClient.autoExposeCapturedCGImage(benchCG, ciContext: ciContext)
            }
            let avgMs = (CFAbsoluteTimeGetCurrent() - startBench) * 1000.0 / 5.0
            assertTrue(
                avgMs < 35.0,
                String(format: "2MP (1620x1080) GPU autoExposeCapturedCGImage completes in %.2f ms (< 35 ms budget for instant inter-shot countdown)", avgMs)
            )
        }
        
        // 9. Studio Strobe + Dark Sequin Curtain + Small Subject / Black Costume / Red Clothing Non-Overexposure & Non-Yellowing Verification
        let strobeW = 240, strobeH = 160
        var strobePixels = [UInt8](repeating: 255, count: strobeW * strobeH * 4)
        for y in 0..<strobeH {
            for x in 0..<strobeW {
                let idx = (y * strobeW + x) * 4
                if x >= 106 && x < 134 && y >= 72 && y < 96 {
                    strobePixels[idx]     = 218
                    strobePixels[idx + 1] = 174
                    strobePixels[idx + 2] = 148
                } else if x >= 98 && x < 142 && y >= 96 && y < 156 {
                    if x >= 112 && x < 128 && y >= 110 && y < 126 {
                        strobePixels[idx]     = 228
                        strobePixels[idx + 1] = 38
                        strobePixels[idx + 2] = 32
                    } else {
                        strobePixels[idx]     = 18
                        strobePixels[idx + 1] = 18
                        strobePixels[idx + 2] = 20
                    }
                } else {
                    strobePixels[idx]     = 12
                    strobePixels[idx + 1] = 18
                    strobePixels[idx + 2] = 34
                }
            }
        }
        if let strobeCtx = CGContext(
            data: &strobePixels,
            width: strobeW,
            height: strobeH,
            bitsPerComponent: 8,
            bytesPerRow: strobeW * 4,
            space: deblockCS,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let rawStrobeCG = strobeCtx.makeImage() {
            let (strobeLuma, strobePeakRGB) = SonyUSBCameraClient.measureSceneLuminance(rawStrobeCG)
            let outStrobeCG = SonyUSBCameraClient.autoExposeCapturedCGImage(rawStrobeCG, ciContext: ciContext)
            let faceBefore = readPixelRGB(rawStrobeCG, x: 120, y: 84)
            let faceAfter = readPixelRGB(outStrobeCG, x: 120, y: 84)
            let redBefore = readPixelRGB(rawStrobeCG, x: 120, y: 118)
            let redAfter = readPixelRGB(outStrobeCG, x: 120, y: 118)
            assertTrue(
                strobeLuma < 0.12 && strobePeakRGB >= 0.72 && outStrobeCG === rawStrobeCG &&
                faceAfter.r == faceBefore.r && faceAfter.g == faceBefore.g && faceAfter.b == faceBefore.b &&
                redAfter.r == redBefore.r && redAfter.g == redBefore.g,
                String(format: "Studio strobe small subject on dark curtain (meanY=%.3f, p98Peak=%.3f) receives 0.0 EV boost with zero yellowing (face RGB=%d,%d,%d)", strobeLuma, strobePeakRGB, faceAfter.r, faceAfter.g, faceAfter.b)
            )
            
            var tallPixels = strobePixels
            for y in 40..<156 {
                for x in 80..<160 {
                    let idx = (y * strobeW + x) * 4
                    tallPixels[idx]     = 216
                    tallPixels[idx + 1] = 172
                    tallPixels[idx + 2] = 146
                }
            }
            if let tallCtx = CGContext(
                data: &tallPixels,
                width: strobeW,
                height: strobeH,
                bitsPerComponent: 8,
                bytesPerRow: strobeW * 4,
                space: deblockCS,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let tallStrobeCG = tallCtx.makeImage() {
                var poseURLs: [URL] = []
                for (idx, cg) in [tallStrobeCG, tallStrobeCG, tallStrobeCG, rawStrobeCG].enumerated() {
                    let u = tempDir.appendingPathComponent("sony_pose_\(idx)_\(UUID().uuidString).jpg")
                    try UIImage(cgImage: cg).jpegData(compressionQuality: 0.92)!.write(to: u)
                    poseURLs.append(u)
                }
                if let poseGIFURL = GIFService.createGIF(from: poseURLs.map(\.absoluteString), frameDuration: 0.25),
                   let refGIFURL = GIFService.createGIF(from: [poseURLs[3].absoluteString, poseURLs[3].absoluteString], frameDuration: 0.25),
                   let poseSrc = CGImageSourceCreateWithURL(poseGIFURL as CFURL, nil),
                   let refSrc = CGImageSourceCreateWithURL(refGIFURL as CFURL, nil),
                   CGImageSourceGetCount(poseSrc) == 4,
                   let frame3CG = CGImageSourceCreateImageAtIndex(poseSrc, 3, nil),
                   let refCG = CGImageSourceCreateImageAtIndex(refSrc, 0, nil) {
                    let fx = Int((Double(frame3CG.width) * 0.5).rounded())
                    let fy = Int((Double(frame3CG.height) * 84.0 / 160.0).rounded())
                    let crouchFace = readPixelRGB(frame3CG, x: fx, y: fy)
                    let refFace = readPixelRGB(refCG, x: fx, y: fy)
                    assertTrue(
                        abs(crouchFace.r - refFace.r) <= 2 && abs(crouchFace.g - refFace.g) <= 2,
                        "GIFService burst with guest crouching against dark curtain under constant strobe preserves face exposure without blowing out (face RGB=\(crouchFace.r),\(crouchFace.g),\(crouchFace.b) vs reference \(refFace.r),\(refFace.g),\(refFace.b))"
                    )
                    try? FileManager.default.removeItem(at: poseGIFURL)
                    try? FileManager.default.removeItem(at: refGIFURL)
                }
                for u in poseURLs { try? FileManager.default.removeItem(at: u) }
            }
        }
        
        try runBackdropAndForegroundQATests(ciContext: ciContext)
    }
    
    // MARK: - AI Background & Foreground Overlays + Mac Post-Event Workflow QA Suite
    
    private static func makeSolidOrBorderCGImage(
        width: Int,
        height: Int,
        fillRGBA: (UInt8, UInt8, UInt8, UInt8),
        borderThickness: Int = 0,
        borderRGBA: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0),
        rightMarkerRGBA: (UInt8, UInt8, UInt8, UInt8)? = nil
    ) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isBorder = borderThickness > 0 && (
                    x < borderThickness || x >= (width - borderThickness) ||
                    y < borderThickness || y >= (height - borderThickness)
                )
                var c = isBorder ? borderRGBA : fillRGBA
                if let marker = rightMarkerRGBA, x >= (width - 16) && x < (width - 4) && y >= (height / 2 - 8) && y < (height / 2 + 8) {
                    c = marker
                }
                let idx = (y * width + x) * 4
                // Premultiplied alpha
                let a = UInt16(c.3)
                pixels[idx]     = UInt8((UInt16(c.0) * a) / 255)
                pixels[idx + 1] = UInt8((UInt16(c.1) * a) / 255)
                pixels[idx + 2] = UInt8((UInt16(c.2) * a) / 255)
                pixels[idx + 3] = c.3
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
    
    private static func encodePNG(_ cgImage: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
    
    private static func encodeJPEGWithEXIF(_ cgImage: CGImage, dateTimeOriginal: String) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
    
    private static func runBackdropAndForegroundQATests(ciContext: CIContext) throws {
        print("\n--- AI BACKDROP & FOREGROUND + MAC BATCH WORKFLOW QA SUITE ---")
        let fm = FileManager.default
        let qaRoot = fm.temporaryDirectory.appendingPathComponent("pb2_backdrop_qa_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: qaRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: qaRoot) }
        
        // 1. Zero-Code Folder Auto-Discovery & Pairing (`_bg` + `_fg` -> Combo)
        let sampleBackdropsDir = qaRoot.appendingPathComponent("SampleBackdrops", isDirectory: true)
        try fm.createDirectory(at: sampleBackdropsDir, withIntermediateDirectories: true)
        
        let redBgCG = makeSolidOrBorderCGImage(width: 120, height: 180, fillRGBA: (220, 30, 30, 255))
        let greenFrameCG = makeSolidOrBorderCGImage(
            width: 100,
            height: 100,
            fillRGBA: (0, 0, 0, 0),
            borderThickness: 12,
            borderRGBA: (20, 210, 60, 255)
        )
        try encodeJPEGWithEXIF(redBgCG, dateTimeOriginal: "2026:10:15 12:00:00")
            .write(to: sampleBackdropsDir.appendingPathComponent("Eiffel Tower_bg.jpg"))
        try encodeJPEGWithEXIF(redBgCG, dateTimeOriginal: "2026:10:15 12:00:00")
            .write(to: sampleBackdropsDir.appendingPathComponent("Magazine_bg.jpg"))
        try encodePNG(greenFrameCG)
            .write(to: sampleBackdropsDir.appendingPathComponent("Magazine_fg.png"))
        try encodePNG(greenFrameCG)
            .write(to: sampleBackdropsDir.appendingPathComponent("Evans Bar Mitzvah_fg.png"))
        
        let discovered = BackdropManager.discoverBackdrops(in: [sampleBackdropsDir])
        assertEqual(discovered.count, 3, "BackdropManager.discoverBackdrops auto-discovers and pairs 3 items from 4 files")
        let eiffel = discovered.first(where: { $0.id == "eiffel_tower" })
        let magazine = discovered.first(where: { $0.id == "magazine" })
        let mitzvah = discovered.first(where: { $0.id == "evans_bar_mitzvah" })
        assertTrue(
            eiffel != nil && eiffel!.hasBackground && !eiffel!.hasForeground && eiffel!.displayName == "Eiffel Tower",
            "Discovered Background-only item ('Eiffel Tower')"
        )
        assertTrue(
            magazine != nil && magazine!.isCombo && magazine!.displayName == "Magazine",
            "Discovered paired Background + Foreground Combo ('Magazine')"
        )
        assertTrue(
            mitzvah != nil && !mitzvah!.hasBackground && mitzvah!.hasForeground && mitzvah!.displayName == "Evans Bar Mitzvah",
            "Discovered Foreground-only transparent frame ('Evans Bar Mitzvah')"
        )
        
        // 2. Resolution Auto-Scaling & 3-Layer Compositing Order (Background -> Subject -> Foreground)
        let subjectCG = makeSolidOrBorderCGImage(width: 240, height: 160, fillRGBA: (30, 90, 230, 255))
        let maskCG = makeSolidOrBorderCGImage(
            width: 240,
            height: 160,
            fillRGBA: (255, 255, 255, 255),
            borderThickness: 50,
            borderRGBA: (0, 0, 0, 255)
        )
        let maskCI = CIImage(cgImage: maskCG)
        
        if let comboItem = magazine {
            let compositedCG = BackdropCompositorService.composite(
                cgImage: subjectCG,
                backdrop: comboItem,
                quality: .captureAccurate,
                ciContext: ciContext,
                additionalSearchDirectories: [sampleBackdropsDir],
                customMaskProvider: { _ in maskCI }
            )
            assertEqual(compositedCG.width, 240, "Composited output preserves exact subject width (240)")
            assertEqual(compositedCG.height, 160, "Composited output preserves exact subject height (160)")
            
            let borderPx = readPixelRGB(compositedCG, x: 4, y: 4)       // Outer frame border -> Green Foreground
            let bgRingPx = readPixelRGB(compositedCG, x: 36, y: 36)     // Outside mask, inside frame -> Red Background
            let centerPx = readPixelRGB(compositedCG, x: 120, y: 80)    // Inside mask, inside frame hole -> Blue Subject
            
            assertTrue(
                borderPx.g > 170 && borderPx.r < 60 && borderPx.b < 90,
                "Layer 3 (Foreground Frame) stretches to all 4 edges on top of background & subject: RGB=(\(borderPx.r),\(borderPx.g),\(borderPx.b))"
            )
            assertTrue(
                bgRingPx.r > 170 && bgRingPx.g < 70 && bgRingPx.b < 70,
                "Layer 1 (Background) replaces physical background outside person mask: RGB=(\(bgRingPx.r),\(bgRingPx.g),\(bgRingPx.b))"
            )
            assertTrue(
                centerPx.b > 180 && centerPx.r < 70,
                "Layer 2 (Segmented Subject) remains intact in front of background and behind frame hole: RGB=(\(centerPx.r),\(centerPx.g),\(centerPx.b))"
            )
        }
        
        // 3. Foreground-Only Fast Path (Bypasses Vision Segmentation Completely)
        var maskProviderCallCount = 0
        if let frameOnlyItem = mitzvah {
            let framedCG = BackdropCompositorService.composite(
                cgImage: subjectCG,
                backdrop: frameOnlyItem,
                quality: .captureAccurate,
                ciContext: ciContext,
                additionalSearchDirectories: [sampleBackdropsDir],
                customMaskProvider: { _ in
                    maskProviderCallCount += 1
                    return maskCI
                }
            )
            let edgePx = readPixelRGB(framedCG, x: 4, y: 4)
            let centerPx = readPixelRGB(framedCG, x: 120, y: 80)
            assertEqual(maskProviderCallCount, 0, "Foreground-only frame bypasses person segmentation (0 mask evaluations)")
            assertTrue(
                edgePx.g > 170 && centerPx.b > 180,
                "Foreground-only frame composites green border over untouched blue subject"
            )
        }
        
        // 4. GIF 4-Frame Luminance Equalization BEFORE Backdrop Compositing (Zero Static Border Flicker)
        var gifBurstURLs: [URL] = []
        let rawLumas: [UInt8] = [102, 105, 104, 136]
        for (idx, val) in rawLumas.enumerated() {
            let rawFrameCG = makeSyntheticLightingScene(
                bgRGB: (val, val, val),
                subjectSkinRGB: (val &+ 10, val, val &- 8),
                shirtRGB: (val &- 10, val, val &+ 8)
            )
            let url = qaRoot.appendingPathComponent("sony_gif_bd_\(idx).jpg")
            try UIImage(cgImage: rawFrameCG).jpegData(compressionQuality: 0.92)!.write(to: url)
            gifBurstURLs.append(url)
        }
        if let frameOnlyItem = mitzvah,
           let compiledGIF = GIFService.createGIF(
               from: gifBurstURLs.map(\.absoluteString),
               frameDuration: 0.25,
               resolution: 0,
               backdrop: frameOnlyItem,
               additionalSearchDirectories: [sampleBackdropsDir]
           ),
           let gifSrc = CGImageSourceCreateWithURL(compiledGIF as CFURL, nil) {
            let count = CGImageSourceGetCount(gifSrc)
            var borderGreens: [Int] = []
            for i in 0..<count {
                if let fCG = CGImageSourceCreateImageAtIndex(gifSrc, i, nil) {
                    borderGreens.append(readPixelRGB(fCG, x: 2, y: 2).g)
                }
            }
            if let minG = borderGreens.min(), let maxG = borderGreens.max() {
                assertTrue(
                    minG > 160 && (maxG - minG) <= 4,
                    "GIFService equalizes raw frames BEFORE compositing foreground frame (border G spread across 4 frames = \(maxG - minG))"
                )
            }
            try? fm.removeItem(at: compiledGIF)
        } else {
            assertTrue(false, "Failed to compile GIF with backdrop")
        }
        
        // 5. Triple-Lock Manifest Matching (PTP 0x1008 Filename + EXIF Timestamp + 8x8 RGB Signature) & SmugMug-Clean Mac Batch Application
        let partyFolder = qaRoot.appendingPathComponent("2026_Party", isDirectory: true)
        try fm.createDirectory(at: partyFolder, withIntermediateDirectories: true)
        
        // Create 3 full-res SD card JPEGs:
        // DSC00001.JPG & DSC00002.JPG have the EXACT SAME second ("2026:10:15 20:15:30") but different subject colors:
        let dsc1Subject = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (30, 80, 220, 255)) // Blue subject
        let dsc2Subject = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (220, 180, 30, 255)) // Gold subject
        let dsc3Subject = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (90, 90, 90, 255))   // Untouched photo (Original)
        
        let dsc1URL = partyFolder.appendingPathComponent("DSC00001.JPG")
        let dsc2URL = partyFolder.appendingPathComponent("DSC00002.JPG")
        let dsc3URL = partyFolder.appendingPathComponent("DSC00003.JPG")
        
        let dsc1Data = encodeJPEGWithEXIF(dsc1Subject, dateTimeOriginal: "2026:10:15 20:15:30")
        let dsc2Data = encodeJPEGWithEXIF(dsc2Subject, dateTimeOriginal: "2026:10:15 20:15:30")
        let dsc3Data = encodeJPEGWithEXIF(dsc3Subject, dateTimeOriginal: "2026:10:15 20:16:10")
        try dsc1Data.write(to: dsc1URL)
        try dsc2Data.write(to: dsc2URL)
        try dsc3Data.write(to: dsc3URL)
        
        // Verify PTP 0x1008 ObjectInfo parser extracts "DSC00001.JPG"
        var mockObjectInfo = Data(count: 52)
        let fnameUTF16 = Array("DSC00001.JPG".utf16) + [0]
        mockObjectInfo.append(UInt8(fnameUTF16.count))
        for unit in fnameUTF16 {
            mockObjectInfo.append(UInt8(unit & 0xFF))
            mockObjectInfo.append(UInt8((unit >> 8) & 0xFF))
        }
        assertEqual(
            BackdropCompositorService.parsePTPObjectInfoFilename(from: mockObjectInfo),
            "DSC00001.JPG",
            "PTP 0x1008 GetObjectInfo parser extracts exact camera filename ('DSC00001.JPG')"
        )
        
        // Build manifest with 2 entries:
        // Entry 1: Matches DSC00002.JPG via EXIF + 8x8 RGB signature (even without PTP filename) -> applies custom embedded Red Background
        // Entry 2: Matches DSC00001.JPG via PTP filename + EXIF -> applies Green Foreground Frame
        let customRedBgBytes = encodeJPEGWithEXIF(redBgCG, dateTimeOriginal: "2026:10:15 12:00:00")
        let customGreenFgBytes = encodePNG(greenFrameCG)
        
        let entryForDSC2 = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: nil, // Force Lock 2 (EXIF) + Lock 3 (8x8 RGB Signature) disambiguation!
            exifDateTimeOriginal: "2026:10:15 20:15:30",
            exifSubSecOriginal: nil,
            rgbSignature8x8: BackdropCompositorService.computeRGBSignature8x8(from: dsc2Subject),
            backdropID: "custom_red",
            backdropDisplayName: "Custom Red",
            backgroundFilename: "CustomRed_bg.jpg",
            foregroundFilename: nil,
            foregroundFitMode: .stretchToEdges,
            customBackgroundData: customRedBgBytes,
            customForegroundData: nil
        )
        let entryForDSC1 = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: "DSC00001.JPG",
            exifDateTimeOriginal: "2026:10:15 20:15:30",
            exifSubSecOriginal: nil,
            rgbSignature8x8: BackdropCompositorService.computeRGBSignature8x8(from: dsc1Subject),
            backdropID: "evans_bar_mitzvah",
            backdropDisplayName: "Evans Bar Mitzvah",
            backgroundFilename: nil,
            foregroundFilename: "Evans Bar Mitzvah_fg.png",
            foregroundFitMode: .stretchToEdges,
            customBackgroundData: nil,
            customForegroundData: customGreenFgBytes
        )
        
        let manifestDoc = BackdropManifestDocument(entries: [entryForDSC2, entryForDSC1])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestJSONURL = partyFolder.appendingPathComponent(BackdropManifestDocument.defaultFilename)
        try encoder.encode(manifestDoc).write(to: manifestJSONURL)
        
        let report1 = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: partyFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(report1.newlyAppliedCount, 2, "Mac batch processor applied backdrops to 2 matched full-res photos in-place")
        assertEqual(report1.unmatchedCount, 0, "Mac batch processor had 0 unmatched manifest entries")
        
        // Check SmugMug-clean file count: ONLY DSC00001.JPG, DSC00002.JPG, DSC00003.JPG, and photobooth_backdrop_manifest.json exist!
        let postFiles = try fm.contentsOfDirectory(at: partyFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let imageFiles = postFiles.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        assertEqual(imageFiles.count, 3, "SmugMug-safe: zero duplicate photos and zero extra .jpg/.png backdrop asset files created in folder")
        
        // Verify DSC00001.JPG got the Green Frame border, DSC00002.JPG got the Red Background, and DSC00003.JPG was untouched
        if let src1 = CGImageSourceCreateWithURL(dsc1URL as CFURL, nil),
           let cg1 = CGImageSourceCreateImageAtIndex(src1, 0, nil),
           let src2 = CGImageSourceCreateWithURL(dsc2URL as CFURL, nil),
           let cg2 = CGImageSourceCreateImageAtIndex(src2, 0, nil),
           let src3 = CGImageSourceCreateWithURL(dsc3URL as CFURL, nil),
           let cg3 = CGImageSourceCreateImageAtIndex(src3, 0, nil) {
            let dsc1Border = readPixelRGB(cg1, x: 3, y: 3)
            let dsc2Bg = readPixelRGB(cg2, x: 10, y: 10)
            let dsc3Px = readPixelRGB(cg3, x: 10, y: 10)
            assertTrue(dsc1Border.g > 170, "DSC00001.JPG received green foreground border in-place")
            assertTrue(dsc2Bg.r > 170 && dsc2Bg.b < 60, "DSC00002.JPG (same-second shot) was disambiguated by 8x8 RGB signature and received red background")
            assertTrue(abs(dsc3Px.r - 90) <= 5 && abs(dsc3Px.g - 90) <= 5, "DSC00003.JPG (Original / no backdrop) remained untouched")
        }
        
        // Run a second time to verify idempotency (PB2_BACKDROP EXIF tag + appliedToFullRes flag)
        let report2 = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: partyFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(report2.newlyAppliedCount, 0, "Idempotency: re-running applyBackdropsToFolder applies 0 times")
        assertEqual(report2.skippedAlreadyAppliedCount, 2, "Idempotency: re-running skips all 2 already-applied photos")
        
        // Verify that replacing DSC00001.JPG with a fresh un-composited SD card original allows re-applying just that photo
        try dsc1Data.write(to: dsc1URL, options: .atomic)
        let report3 = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: partyFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(report3.newlyAppliedCount, 1, "Replacing a single JPEG with fresh un-composited SD card original re-applies backdrop to just that photo")
        assertEqual(report3.skippedAlreadyAppliedCount, 1, "Other already-composited photo remains skipped")
        
        // Verify Lock-2 deleted-photo safety: if a manifest entry's photo was deleted from the folder and an unrelated photo
        // was taken 2 seconds later (within ±3s window) with a completely different RGB signature, it is NOT falsely matched
        let ghostEntry = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: "DSC09999.JPG", // Deleted from folder
            exifDateTimeOriginal: "2026:10:15 20:16:08", // 2s before DSC00003.JPG ("2026:10:15 20:16:10")
            exifSubSecOriginal: nil,
            rgbSignature8x8: BackdropCompositorService.computeRGBSignature8x8(from: redBgCG), // Bright red != grey DSC00003
            backdropID: "evans_bar_mitzvah",
            backdropDisplayName: "Evans Bar Mitzvah",
            backgroundFilename: nil,
            foregroundFilename: "Evans Bar Mitzvah_fg.png",
            foregroundFitMode: .stretchToEdges
        )
        let manifestWithGhost = BackdropManifestDocument(
            entries: [entryForDSC2, entryForDSC1, ghostEntry],
            customAssetsByFilename: ["Evans Bar Mitzvah_fg.png": customGreenFgBytes]
        )
        try encoder.encode(manifestWithGhost).write(to: manifestJSONURL)
        let report4 = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: partyFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(report4.newlyAppliedCount, 0, "Deleted-photo Lock-2 safety: unrelated photo within ±3s window is rejected by 8x8 RGB signature")
        assertEqual(report4.unmatchedCount, 1, "Deleted photo is accurately reported as 1 unmatched entry")
        
        // 6. Front-Camera Pre-Mirroring Orientation (Subject Mirrors Horizontally, Foreground Text Stays Un-Mirrored)
        let rawFrontSubj = makeSolidOrBorderCGImage(
            width: 160,
            height: 120,
            fillRGBA: (40, 40, 40, 255),
            rightMarkerRGBA: (250, 250, 20, 255) // Bright yellow marker on right side of raw image
        )
        let asymmetricFrame = makeSolidOrBorderCGImage(
            width: 160,
            height: 120,
            fillRGBA: (0, 0, 0, 0),
            rightMarkerRGBA: (20, 240, 240, 255) // Cyan marker on right side of foreground frame
        )
        let mirroredSubjCG = BackdropCompositorService.mirrorCGImageHorizontally(rawFrontSubj, ciContext: ciContext)
        let asymFrameURL = sampleBackdropsDir.appendingPathComponent("Asym_fg.png")
        try encodePNG(asymmetricFrame).write(to: asymFrameURL)
        let asymItem = BackdropItem(
            id: "asym",
            displayName: "Asym",
            backgroundFilename: nil,
            foregroundFilename: "Asym_fg.png",
            foregroundFitMode: .stretchToEdges,
            isBundled: true,
            isEnabled: true
        )
        let preMirroredComposite = BackdropCompositorService.composite(
            cgImage: mirroredSubjCG,
            backdrop: asymItem,
            quality: .captureAccurate,
            ciContext: ciContext,
            additionalSearchDirectories: [sampleBackdropsDir]
        )
        let leftSubjCheck = readPixelRGB(preMirroredComposite, x: 10, y: 60)   // Mirrored subject marker is now on the LEFT
        let rightFrameCheck = readPixelRGB(preMirroredComposite, x: 150, y: 60) // Foreground frame marker stays on the RIGHT
        assertTrue(
            leftSubjCheck.r > 200 && leftSubjCheck.g > 200 && rightFrameCheck.g > 200 && rightFrameCheck.b > 200,
            "iPad Front-Camera Pre-Mirroring: subject mirrors horizontally while foreground frame text stays un-reversed"
        )
        
        // 6B. External Camera (`SonyUSBCameraClient`) Live View, Standard Photo, Animated GIF, and Mac Batch Horizontal Mirroring
        let rawSonySubjCG = makeSolidOrBorderCGImage(
            width: 180,
            height: 120,
            fillRGBA: (95, 95, 95, 255),
            rightMarkerRGBA: (250, 250, 20, 255) // Bright yellow marker on RIGHT side of raw external camera frame (x: 164..<176)
        )
        let asymSonyFrameCG = makeSolidOrBorderCGImage(
            width: 180,
            height: 120,
            fillRGBA: (0, 0, 0, 0),
            rightMarkerRGBA: (20, 240, 240, 255) // Cyan marker on RIGHT side of foreground frame (x: 164..<176)
        )
        let asymSonyFrameURL = sampleBackdropsDir.appendingPathComponent("AsymSony_fg.png")
        try encodePNG(asymSonyFrameCG).write(to: asymSonyFrameURL)
        let asymSonyItem = BackdropItem(
            id: "asym_sony",
            displayName: "Asym Sony",
            backgroundFilename: nil,
            foregroundFilename: "AsymSony_fg.png",
            foregroundFitMode: .stretchToEdges,
            isBundled: true,
            isEnabled: true
        )
        let rawSonyJPEGData = encodeJPEGWithEXIF(rawSonySubjCG, dateTimeOriginal: "2026:10:15 21:00:00")
        
        // 6B-1. External Camera Live View (`processLiveViewJPEG`) mirrors subject horizontally while keeping foreground un-reversed
        if let (liveUI, _) = SonyUSBCameraClient.processLiveViewJPEG(
            rawSonyJPEGData,
            backdrop: asymSonyItem,
            ciContext: ciContext,
            additionalSearchDirectories: [sampleBackdropsDir]
        ), let liveCG = liveUI.cgImage {
            let liveLeftSubj = readPixelRGB(liveCG, x: 10, y: 60)
            let liveRightFrame = readPixelRGB(liveCG, x: 170, y: 60)
            assertTrue(
                liveLeftSubj.r > 200 && liveLeftSubj.g > 200 && liveLeftSubj.b < 80 &&
                liveRightFrame.g > 200 && liveRightFrame.b > 200 && liveRightFrame.r < 80,
                "External Camera Live View: subject mirrors horizontally to left (\(liveLeftSubj.r),\(liveLeftSubj.g),\(liveLeftSubj.b)) while foreground frame stays on right (\(liveRightFrame.r),\(liveRightFrame.g),\(liveRightFrame.b))"
            )
        } else {
            assertTrue(false, "External Camera processLiveViewJPEG returned nil")
        }
        
        // 6B-2. External Camera Standard Photo Capture (`normalizeAndAutoExposeCapturedJPEG`) mirrors subject horizontally while keeping foreground un-reversed
        let normSonyStdData = SonyUSBCameraClient.normalizeAndAutoExposeCapturedJPEG(
            rawSonyJPEGData,
            backdrop: asymSonyItem,
            captureMode: .standard,
            additionalSearchDirectories: [sampleBackdropsDir]
        )
        if let stdUI = UIImage(data: normSonyStdData), let stdCG = stdUI.cgImage {
            let stdLeftSubj = readPixelRGB(stdCG, x: 10, y: 60)
            let stdRightFrame = readPixelRGB(stdCG, x: 170, y: 60)
            assertTrue(
                stdLeftSubj.r > 200 && stdLeftSubj.g > 200 && stdLeftSubj.b < 80 &&
                stdRightFrame.g > 200 && stdRightFrame.b > 200 && stdRightFrame.r < 80,
                "External Camera Standard Photo: subject mirrors horizontally to left (\(stdLeftSubj.r),\(stdLeftSubj.g),\(stdLeftSubj.b)) while foreground frame stays on right (\(stdRightFrame.r),\(stdRightFrame.g),\(stdRightFrame.b))"
            )
        } else {
            assertTrue(false, "Failed to decode normalized External Camera standard photo")
        }
        
        // 6B-3. External Camera Animated GIF Capture (`normalizeAndAutoExposeCapturedJPEG` in .gif mode -> `GIFService.createGIF`)
        let normSonyGIFData = SonyUSBCameraClient.normalizeAndAutoExposeCapturedJPEG(
            rawSonyJPEGData,
            backdrop: asymSonyItem,
            captureMode: .gif,
            additionalSearchDirectories: [sampleBackdropsDir]
        )
        let sonyGIFSource1 = qaRoot.appendingPathComponent("sony_mirror_gif_0.jpg")
        let sonyGIFSource2 = qaRoot.appendingPathComponent("sony_mirror_gif_1.jpg")
        try normSonyGIFData.write(to: sonyGIFSource1)
        try normSonyGIFData.write(to: sonyGIFSource2)
        if let compiledMirroredGIF = GIFService.createGIF(
            from: [sonyGIFSource1.absoluteString, sonyGIFSource2.absoluteString],
            frameDuration: 0.25,
            backdrop: asymSonyItem,
            additionalSearchDirectories: [sampleBackdropsDir]
        ),
           let gifSrc = CGImageSourceCreateWithURL(compiledMirroredGIF as CFURL, nil),
           let gifFrame0 = CGImageSourceCreateImageAtIndex(gifSrc, 0, nil) {
            let w = gifFrame0.width
            let h = gifFrame0.height
            let gifLeftSubj = readPixelRGB(gifFrame0, x: Int((Double(w) * 10.0 / 180.0).rounded()), y: h / 2)
            let gifRightFrame = readPixelRGB(gifFrame0, x: Int((Double(w) * 170.0 / 180.0).rounded()), y: h / 2)
            assertTrue(
                gifLeftSubj.r > 190 && gifLeftSubj.g > 190 && gifLeftSubj.b < 90 &&
                gifRightFrame.g > 190 && gifRightFrame.b > 190 && gifRightFrame.r < 90,
                "External Camera Animated GIF: subject is mirrored to left (\(gifLeftSubj.r),\(gifLeftSubj.g),\(gifLeftSubj.b)) while foreground frame stays on right (\(gifRightFrame.r),\(gifRightFrame.g),\(gifRightFrame.b))"
            )
            try? fm.removeItem(at: compiledMirroredGIF)
        } else {
            assertTrue(false, "Failed to compile External Camera mirrored GIF")
        }
        
        // 6B-4. External Camera Mac Batch Full-Resolution Workflow (un-mirrored 8x8 signature match + mirrored subject composite)
        let asymBatchFolder = qaRoot.appendingPathComponent("AsymBatchFolder", isDirectory: true)
        try fm.createDirectory(at: asymBatchFolder, withIntermediateDirectories: true)
        let dscAsymURL = asymBatchFolder.appendingPathComponent("DSC08888.JPG")
        try rawSonyJPEGData.write(to: dscAsymURL)
        let asymSonyFgBytes = encodePNG(asymSonyFrameCG)
        let asymEntry = PhotoBackdropManifestEntry(
            id: UUID(),
            captureTimestampUTC: Date(),
            ptpFilename: nil, // Verify Lock 2 + Lock 3 (un-mirrored 8x8 RGB signature) matches raw SD card JPEG
            exifDateTimeOriginal: "2026:10:15 21:00:00",
            exifSubSecOriginal: nil,
            rgbSignature8x8: BackdropCompositorService.computeRGBSignature8x8(from: rawSonySubjCG),
            backdropID: "asym_sony",
            backdropDisplayName: "Asym Sony",
            backgroundFilename: nil,
            foregroundFilename: "AsymSony_fg.png",
            foregroundFitMode: .stretchToEdges,
            customBackgroundData: nil,
            customForegroundData: asymSonyFgBytes
        )
        let asymDoc = BackdropManifestDocument(entries: [asymEntry])
        try encoder.encode(asymDoc).write(to: asymBatchFolder.appendingPathComponent(BackdropManifestDocument.defaultFilename))
        let asymReport = try BackdropManifestStore.applyBackdropsToFolder(folderURL: asymBatchFolder)
        if asymReport.newlyAppliedCount == 1,
           let srcAsym = CGImageSourceCreateWithURL(dscAsymURL as CFURL, nil),
           let cgAsym = CGImageSourceCreateImageAtIndex(srcAsym, 0, nil) {
            let batchLeftSubj = readPixelRGB(cgAsym, x: 10, y: 60)
            let batchRightFrame = readPixelRGB(cgAsym, x: 170, y: 60)
            assertTrue(
                batchLeftSubj.r > 200 && batchLeftSubj.g > 200 && batchLeftSubj.b < 80 &&
                batchRightFrame.g > 200 && batchRightFrame.b > 200 && batchRightFrame.r < 80,
                "Mac Batch Full-Res Processor: matches raw SD card JPEG via un-mirrored 8x8 signature and mirrors subject horizontally while keeping foreground frame un-reversed"
            )
        } else {
            assertTrue(false, "Mac Batch Full-Res Processor failed on asymmetric external camera photo")
        }
        
        // 6C. Real-World Event Manifest Robustness Suite:
        //     - Exact 15-Entry User Scenario (`DSC09816`..`DSC09829` deleted pre-format test shots with corrupted `matchedFullResFilename`,
        //       `DSC09830`..`DSC09832` Snowy Peaks, `DSC09833`..`DSC09835` No-Background, `DSC09836`..`DSC09838` Golden Gate Bridge)
        //     - Interleaved GIFs & Old GIFs (<24h) in Folder
        //     - Multiple `manifest.json` Files (`photobooth_backdrop_manifest.json` + `photobooth_backdrop_manifest 2.json`) from App Restart
        //     - SD Card Format in `Reset` Mode (`DSC00001.JPG` Filename Reuse for Roving Photo & No-Background Photo)
        let realWorldFolder = qaRoot.appendingPathComponent("RealWorld_DSC09830_09838", isDirectory: true)
        try fm.createDirectory(at: realWorldFolder, withIntermediateDirectories: true)
        
        let snowyBgCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (20, 180, 245, 255))    // Cyan-Blue (Snowy Peaks)
        let ggbBgCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (240, 80, 20, 255))      // Orange-Red (Golden Gate Bridge)
        let speyBgCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (180, 120, 20, 255))    // Amber (Spey Whisky - DELETED)
        let timeFgCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (0, 0, 0, 0), borderThickness: 12, borderRGBA: (230, 10, 10, 255))
        let eiffelBgCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (130, 30, 200, 255))  // Purple (Eiffel - DELETED)
        
        let snowyBytes = encodeJPEGWithEXIF(snowyBgCG, dateTimeOriginal: "2026:10:18 12:00:00")
        let ggbBytes = encodeJPEGWithEXIF(ggbBgCG, dateTimeOriginal: "2026:10:18 12:00:00")
        let speyBytes = encodeJPEGWithEXIF(speyBgCG, dateTimeOriginal: "2026:10:18 12:00:00")
        let timeBytes = encodePNG(timeFgCG)
        let eiffelBytes = encodeJPEGWithEXIF(eiffelBgCG, dateTimeOriginal: "2026:10:18 12:00:00")
        
        // Tripod room scene with near-identical 8x8 RGB signature across the entire evening (dist < 0.03 between all shots!)
        let tripodRoomSubjCG = makeSolidOrBorderCGImage(width: 180, height: 120, fillRGBA: (145, 130, 110, 255))
        let tripodRoomSig = BackdropCompositorService.computeRGBSignature8x8(from: tripodRoomSubjCG)
        
        // Write the 9 post-format SD card JPEGs (`DSC09830.JPG` .. `DSC09838.JPG`) into `realWorldFolder`:
        let sdCardShots: [(name: String, exifDT: String)] = [
            ("DSC09830.JPG", "2026:10:18 20:38:52"),
            ("DSC09831.JPG", "2026:10:18 20:38:56"),
            ("DSC09832.JPG", "2026:10:18 20:39:01"),
            ("DSC09833.JPG", "2026:10:18 20:40:00"), // No background (Original)
            ("DSC09834.JPG", "2026:10:18 20:40:04"), // No background (Original)
            ("DSC09835.JPG", "2026:10:18 20:40:08"), // No background (Original)
            ("DSC09836.JPG", "2026:10:18 20:40:48"),
            ("DSC09837.JPG", "2026:10:18 20:40:52"),
            ("DSC09838.JPG", "2026:10:18 20:40:56")
        ]
        for shot in sdCardShots {
            let url = realWorldFolder.appendingPathComponent(shot.name)
            try encodeJPEGWithEXIF(tripodRoomSubjCG, dateTimeOriginal: shot.exifDT).write(to: url)
        }
        // Also place old GIFs from <24h ago and a current-session GIF into the same folder
        try Data("GIF89a_old_session".utf8).write(to: realWorldFolder.appendingPathComponent("4231F25C-AD33-4F26-AC53-0D73D25BDAC0.gif"))
        try Data("GIF89a_current_session".utf8).write(to: realWorldFolder.appendingPathComponent("A448AC27-B568-4A0F-9D6E-2854BD8A16AC.gif"))
        
        let isoFormatter = ISO8601DateFormatter()
        func makeTestEntry(
            utc: String,
            ptp: String,
            exifDT: String,
            subSec: String,
            backdropID: String,
            bgFile: String?,
            fgFile: String? = nil,
            applied: Bool = false,
            corruptedMatched: String? = nil
        ) -> PhotoBackdropManifestEntry {
            PhotoBackdropManifestEntry(
                id: UUID(),
                captureTimestampUTC: isoFormatter.date(from: utc) ?? Date(),
                ptpFilename: ptp,
                exifDateTimeOriginal: exifDT,
                exifSubSecOriginal: subSec,
                rgbSignature8x8: tripodRoomSig,
                backdropID: backdropID,
                backdropDisplayName: backdropID,
                backgroundFilename: bgFile,
                foregroundFilename: fgFile,
                foregroundFitMode: .stretchToEdges,
                appliedToFullRes: applied,
                matchedFullResFilename: corruptedMatched
            )
        }
        
        // Split the 15 entries across TWO manifest files in the same folder (`photobooth_backdrop_manifest.json` and
        // `photobooth_backdrop_manifest 2.json`) to simultaneously verify Condition 3 & 4 (app restart / multiple manifests)
        // AND self-healing of previously corrupted `matchedFullResFilename` values!
        let manifestPart1Entries: [PhotoBackdropManifestEntry] = [
            // 9 deleted pre-format test shots (20:31..20:36) with corrupted `matchedFullResFilename` from prior buggy run:
            makeTestEntry(utc: "2026-10-19T03:31:28Z", ptp: "DSC09816.JPG", exifDT: "2026:10:18 20:31:25", subSec: "991", backdropID: "301_scottish_spey_whisky", bgFile: "301_scottish_spey_whisky_bg.jpg", applied: true, corruptedMatched: "DSC09838.JPG"),
            makeTestEntry(utc: "2026-10-19T03:31:33Z", ptp: "DSC09818.JPG", exifDT: "2026:10:18 20:31:31", subSec: "391", backdropID: "301_scottish_spey_whisky", bgFile: "301_scottish_spey_whisky_bg.jpg", applied: true, corruptedMatched: "DSC09836.JPG"),
            makeTestEntry(utc: "2026-10-19T03:31:38Z", ptp: "DSC09820.JPG", exifDT: "2026:10:18 20:31:36", subSec: "623", backdropID: "301_scottish_spey_whisky", bgFile: "301_scottish_spey_whisky_bg.jpg", applied: true, corruptedMatched: "DSC09830.JPG"),
            makeTestEntry(utc: "2026-10-19T03:33:25Z", ptp: "DSC09824.JPG", exifDT: "2026:10:18 20:33:22", subSec: "467", backdropID: "501_time_person_of_the_year", bgFile: nil, fgFile: "501_time_person_of_the_year_fg.png", applied: true, corruptedMatched: "DSC09834.JPG"),
            makeTestEntry(utc: "2026-10-19T03:33:28Z", ptp: "DSC09825.JPG", exifDT: "2026:10:18 20:33:26", subSec: "326", backdropID: "501_time_person_of_the_year", bgFile: nil, fgFile: "501_time_person_of_the_year_fg.png", applied: true, corruptedMatched: "DSC09833.JPG"),
            makeTestEntry(utc: "2026-10-19T03:33:33Z", ptp: "DSC09826.JPG", exifDT: "2026:10:18 20:33:30", subSec: "723", backdropID: "501_time_person_of_the_year", bgFile: nil, fgFile: "501_time_person_of_the_year_fg.png"),
            makeTestEntry(utc: "2026-10-19T03:36:33Z", ptp: "DSC09827.JPG", exifDT: "2026:10:18 20:36:30", subSec: "481", backdropID: "303_eiffel_tower_night", bgFile: "303_eiffel_tower_night_bg.jpg"),
            makeTestEntry(utc: "2026-10-19T03:36:37Z", ptp: "DSC09828.JPG", exifDT: "2026:10:18 20:36:34", subSec: "391", backdropID: "303_eiffel_tower_night", bgFile: "303_eiffel_tower_night_bg.jpg"),
            makeTestEntry(utc: "2026-10-19T03:36:41Z", ptp: "DSC09829.JPG", exifDT: "2026:10:18 20:36:38", subSec: "623", backdropID: "303_eiffel_tower_night", bgFile: "303_eiffel_tower_night_bg.jpg"),
            // First 3 post-format shots (Snowy Peaks):
            makeTestEntry(utc: "2026-10-19T03:38:55Z", ptp: "DSC09830.JPG", exifDT: "2026:10:18 20:38:52", subSec: "361", backdropID: "101_snowy_peaks", bgFile: "101_snowy_peaks_bg.jpg", applied: true, corruptedMatched: "DSC09832.JPG"),
            makeTestEntry(utc: "2026-10-19T03:38:59Z", ptp: "DSC09831.JPG", exifDT: "2026:10:18 20:38:56", subSec: "600", backdropID: "101_snowy_peaks", bgFile: "101_snowy_peaks_bg.jpg", applied: true, corruptedMatched: "DSC09831.JPG"),
            makeTestEntry(utc: "2026-10-19T03:39:03Z", ptp: "DSC09832.JPG", exifDT: "2026:10:18 20:39:01", subSec: "136", backdropID: "101_snowy_peaks", bgFile: "101_snowy_peaks_bg.jpg", applied: true, corruptedMatched: "DSC09835.JPG")
        ]
        // Second manifest file created after simulated app restart (`photobooth_backdrop_manifest 2.json`):
        let manifestPart2Entries: [PhotoBackdropManifestEntry] = [
            // Duplicate of DSC09832.JPG + 3 Golden Gate Bridge shots:
            manifestPart1Entries.last!,
            makeTestEntry(utc: "2026-10-19T03:40:51Z", ptp: "DSC09836.JPG", exifDT: "2026:10:18 20:40:48", subSec: "476", backdropID: "305_golden_gate_bridge", bgFile: "305_golden_gate_bridge_bg.jpg", applied: true, corruptedMatched: "DSC09837.JPG"),
            makeTestEntry(utc: "2026-10-19T03:40:54Z", ptp: "DSC09837.JPG", exifDT: "2026:10:18 20:40:52", subSec: "242", backdropID: "305_golden_gate_bridge", bgFile: "305_golden_gate_bridge_bg.jpg"),
            makeTestEntry(utc: "2026-10-19T03:40:59Z", ptp: "DSC09838.JPG", exifDT: "2026:10:18 20:40:56", subSec: "790", backdropID: "305_golden_gate_bridge", bgFile: "305_golden_gate_bridge_bg.jpg")
        ]
        let customAssetMap: [String: Data] = [
            "101_snowy_peaks_bg.jpg": snowyBytes,
            "305_golden_gate_bridge_bg.jpg": ggbBytes,
            "301_scottish_spey_whisky_bg.jpg": speyBytes,
            "501_time_person_of_the_year_fg.png": timeBytes,
            "303_eiffel_tower_night_bg.jpg": eiffelBytes
        ]
        
        try encoder.encode(BackdropManifestDocument(entries: manifestPart1Entries, customAssetsByFilename: customAssetMap))
            .write(to: realWorldFolder.appendingPathComponent("photobooth_backdrop_manifest.json"))
        try encoder.encode(BackdropManifestDocument(entries: manifestPart2Entries, customAssetsByFilename: customAssetMap))
            .write(to: realWorldFolder.appendingPathComponent("photobooth_backdrop_manifest 2.json"))
        
        let rwReport = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: realWorldFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(rwReport.newlyAppliedCount, 6, "Real-world 15-entry scenario applies backdrops to exactly 6 photos (3 Snowy Peaks + 3 Golden Gate Bridge)")
        
        for name in ["DSC09830.JPG", "DSC09831.JPG", "DSC09832.JPG"] {
            let (_, _, tag) = BackdropCompositorService.extractEXIFTimestamps(from: realWorldFolder.appendingPathComponent(name))
            assertEqual(tag, "101_snowy_peaks", "\(name) received Snowy Peaks backdrop (101_snowy_peaks)")
        }
        for name in ["DSC09833.JPG", "DSC09834.JPG", "DSC09835.JPG"] {
            let (_, _, tag) = BackdropCompositorService.extractEXIFTimestamps(from: realWorldFolder.appendingPathComponent(name))
            assertEqual(tag, nil, "\(name) (No Background / Original) remained 100% untouched (nil PB2_BACKDROP tag)")
        }
        for name in ["DSC09836.JPG", "DSC09837.JPG", "DSC09838.JPG"] {
            let (_, _, tag) = BackdropCompositorService.extractEXIFTimestamps(from: realWorldFolder.appendingPathComponent(name))
            assertEqual(tag, "305_golden_gate_bridge", "\(name) received Golden Gate Bridge backdrop (305_golden_gate_bridge)")
        }
        
        // 6D. SD Card Format in `Reset` Mode (`DSC00001.JPG` Filename Reuse) + Roving Disconnected Camera Photos + `.none` Capture Protection
        let resetCardFolder = qaRoot.appendingPathComponent("ResetCardFolder", isDirectory: true)
        try fm.createDirectory(at: resetCardFolder, withIntermediateDirectories: true)
        // Suppose earlier before formatting the SD card, DSC00001.JPG and DSC00002.JPG were taken at 19:00 with Spey Whisky:
        let staleResetEntry1 = makeTestEntry(utc: "2026-10-19T02:00:05Z", ptp: "DSC00001.JPG", exifDT: "2026:10:18 19:00:02", subSec: "100", backdropID: "301_scottish_spey_whisky", bgFile: "301_scottish_spey_whisky_bg.jpg")
        let staleResetEntry2 = makeTestEntry(utc: "2026-10-19T02:00:10Z", ptp: "DSC00002.JPG", exifDT: "2026:10:18 19:00:07", subSec: "200", backdropID: "301_scottish_spey_whisky", bgFile: "301_scottish_spey_whisky_bg.jpg")
        // Then SD card was formatted (resetting counter to DSC00001.JPG) at 21:00:
        // - New DSC00001.JPG at 21:00:10 is taken in photobooth with NO background (`none`)
        // - New DSC00002.JPG at 21:00:20 is taken with camera DISCONNECTED (roving photo, so no new manifest entry!)
        // - New DSC00003.JPG at 21:00:30 is taken in photobooth with Golden Gate Bridge
        let newNoneEntry1 = makeTestEntry(utc: "2026-10-19T04:00:12Z", ptp: "DSC00001.JPG", exifDT: "2026:10:18 21:00:10", subSec: "500", backdropID: "none", bgFile: nil, fgFile: nil)
        let newGGBEntry3 = makeTestEntry(utc: "2026-10-19T04:00:32Z", ptp: "DSC00003.JPG", exifDT: "2026:10:18 21:00:30", subSec: "800", backdropID: "305_golden_gate_bridge", bgFile: "305_golden_gate_bridge_bg.jpg")
        
        try encodeJPEGWithEXIF(tripodRoomSubjCG, dateTimeOriginal: "2026:10:18 21:00:10").write(to: resetCardFolder.appendingPathComponent("DSC00001.JPG"))
        try encodeJPEGWithEXIF(tripodRoomSubjCG, dateTimeOriginal: "2026:10:18 21:00:20").write(to: resetCardFolder.appendingPathComponent("DSC00002.JPG"))
        try encodeJPEGWithEXIF(tripodRoomSubjCG, dateTimeOriginal: "2026:10:18 21:00:30").write(to: resetCardFolder.appendingPathComponent("DSC00003.JPG"))
        
        let resetManifestDoc = BackdropManifestDocument(
            entries: [staleResetEntry1, staleResetEntry2, newNoneEntry1, newGGBEntry3],
            customAssetsByFilename: customAssetMap
        )
        try encoder.encode(resetManifestDoc).write(to: resetCardFolder.appendingPathComponent(BackdropManifestDocument.defaultFilename))
        
        let resetReport = try BackdropManifestStore.applyBackdropsToFolder(
            folderURL: resetCardFolder,
            customMaskProvider: { _ in maskCI }
        )
        assertEqual(resetReport.newlyAppliedCount, 1, "SD Card Reset Mode: only DSC00003.JPG receives a backdrop; reused DSC00001 (No Background) and DSC00002 (disconnected roving photo) are protected by EXIF timestamp veto")
        assertEqual(BackdropCompositorService.extractEXIFTimestamps(from: resetCardFolder.appendingPathComponent("DSC00001.JPG")).backdropAppliedID, nil, "Reused DSC00001.JPG (No Background) is untouched despite stale pre-format DSC00001.JPG entry")
        assertEqual(BackdropCompositorService.extractEXIFTimestamps(from: resetCardFolder.appendingPathComponent("DSC00002.JPG")).backdropAppliedID, nil, "Reused DSC00002.JPG (disconnected roving photo) is untouched despite stale pre-format DSC00002.JPG entry")
        assertEqual(BackdropCompositorService.extractEXIFTimestamps(from: resetCardFolder.appendingPathComponent("DSC00003.JPG")).backdropAppliedID, "305_golden_gate_bridge", "DSC00003.JPG receives Golden Gate Bridge backdrop")
        
        // 7. Touch-Shield Hit-Testing Verification (`BackdropPickerOverlayView.isPointInsideShield`)
        let iPadScreen = CGSize(width: 1194, height: 834)
        let bottomCenterTap = CGPoint(x: 597, y: 800)
        let slightlyMissedPillTap = CGPoint(x: 450, y: 745)
        let upperGIFButtonTap = CGPoint(x: 597, y: 200)
        let middlePhotoButtonTap = CGPoint(x: 597, y: 520)
        assertTrue(
            BackdropPickerOverlayView.isPointInsideShield(bottomCenterTap, screenSize: iPadScreen, isExpanded: false) &&
            BackdropPickerOverlayView.isPointInsideShield(slightlyMissedPillTap, screenSize: iPadScreen, isExpanded: false),
            "Bottom touch-absorbing shield intercepts taps on and around the collapsed backdrop pill"
        )
        assertTrue(
            !BackdropPickerOverlayView.isPointInsideShield(upperGIFButtonTap, screenSize: iPadScreen, isExpanded: true) &&
            !BackdropPickerOverlayView.isPointInsideShield(middlePhotoButtonTap, screenSize: iPadScreen, isExpanded: true),
            "Upper GIF and middle Photo capture tap areas remain unobstructed when carousel is expanded"
        )
        
        // 8. Missing-Asset Pre-Check Protection (Prevents False Overwrite / PB2_BACKDROP Stamp When Asset Is Missing)
        let missingAssetItem = BackdropItem(
            id: "deleted_backdrop",
            displayName: "Deleted Backdrop",
            backgroundFilename: "MissingAsset_bg.jpg",
            foregroundFilename: nil,
            foregroundFitMode: .stretchToEdges,
            isBundled: false,
            isEnabled: true
        )
        assertTrue(
            !BackdropCompositorService.hasResolvableAssets(
                for: missingAssetItem,
                customBackgroundData: nil,
                customForegroundData: nil,
                additionalSearchDirectories: [sampleBackdropsDir]
            ),
            "BackdropCompositorService.hasResolvableAssets returns false when referenced asset is missing from disk and manifest"
        )
        assertTrue(
            BackdropCompositorService.hasResolvableAssets(
                for: missingAssetItem,
                customBackgroundData: customRedBgBytes,
                customForegroundData: nil,
                additionalSearchDirectories: [sampleBackdropsDir]
            ),
            "BackdropCompositorService.hasResolvableAssets returns true when custom asset bytes are embedded in manifest JSON"
        )
        
        // 9. Live View Vision .balanced Matte Solidification & Motion-Adaptive Temporal EMA Stabilization
        let liveLUT = BackdropCompositorService.liveMatteLUT
        assertEqual(liveLUT[0], 0, "Live matte LUT clamps 0 to 0")
        assertEqual(liveLUT[45], 0, "Live matte LUT suppresses background clutter noise (45/255 -> 0)")
        assertEqual(liveLUT[205], 255, "Live matte LUT solidifies interior person confidence (205/255 -> 255, zero see-through clothes)")
        assertTrue(
            liveLUT[125] > 100 && liveLUT[125] < 155,
            "Live matte LUT preserves smooth anti-aliased boundary transition at midpoint (liveLUT[125]=\(liveLUT[125]))"
        )
        
        var temporalBuf: [UInt8] = []
        let frameA: [UInt8] = [30, 118, 210, 0]   // [bg noise, edge shimmer A, person interior, empty]
        let frameB: [UInt8] = [35, 134, 215, 240] // [bg noise, edge shimmer B (+16), person interior, fast hand wave (+240)]
        frameA.withUnsafeBufferPointer { ptr in
            BackdropCompositorService.solidifyAndTemporalSmoothMask(
                rawRowBytes: ptr.baseAddress!,
                width: 4,
                height: 1,
                srcBytesPerRow: 4,
                lut: liveLUT,
                temporalBuffer: &temporalBuf,
                enableTemporalSmoothing: false
            )
        }
        let edgeAfterFrameA = Int(temporalBuf[1])
        frameB.withUnsafeBufferPointer { ptr in
            BackdropCompositorService.solidifyAndTemporalSmoothMask(
                rawRowBytes: ptr.baseAddress!,
                width: 4,
                height: 1,
                srcBytesPerRow: 4,
                lut: liveLUT,
                temporalBuffer: &temporalBuf,
                enableTemporalSmoothing: true
            )
        }
        let unsmoothedEdgeB = Int(liveLUT[134])
        let smoothedEdgeB = Int(temporalBuf[1])
        let fastHandWaveOut = Int(temporalBuf[3])
        assertTrue(
            temporalBuf[0] == 0 && temporalBuf[2] == 255 &&
            abs(smoothedEdgeB - edgeAfterFrameA) < abs(unsmoothedEdgeB - edgeAfterFrameA) &&
            fastHandWaveOut >= 235,
            "Motion-adaptive temporal EMA dampens stationary edge shimmer (\(edgeAfterFrameA)->\(smoothedEdgeB) vs raw \(unsmoothedEdgeB)) while fast motion responds immediately (\(fastHandWaveOut)/255)"
        )
        
        // 10. 3:2 Landscape Aspect Ratio & Top/Bottom Letterboxing Across All Configurations (Live View, Photos, GIFs)
        let iPad4x3Screen = CGSize(width: 1366, height: 1024)   // 4:3 iPad screen (1.333:1)
        let iPad11ScreenSize = CGSize(width: 1194, height: 834) // 11-inch iPad screen (1.432:1)
        
        // 10a. Verify iPad Front Camera (4:3 raw sensor: 1440x1080 Live View & 4032x3024 Photo) is oriented, mirrored,
        //      and center-cropped to exact 3:2 landscape (1440x960 and 4032x2688) regardless of UIDeviceOrientation.
        let rawFrontLiveCI = CIImage(cgImage: makeSolidOrBorderCGImage(width: 1440, height: 1080, fillRGBA: (40, 120, 220, 255)))
        for testOrientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait, .portraitUpsideDown, .unknown] {
            let processedCI = BackdropCompositorService.orientAndMirrorFrontCameraCIImage(
                rawFrontLiveCI,
                interfaceOrientation: testOrientation
            )
            assertEqual(Int(processedCI.extent.width), 1440, "Front camera 1440x1080 preserves full 1440 width for orientation \(testOrientation.rawValue)")
            assertEqual(Int(processedCI.extent.height), 960, "Front camera 1440x1080 center-crops height to 960 (3:2) for orientation \(testOrientation.rawValue)")
            assertTrue(
                abs((processedCI.extent.width / processedCI.extent.height) - 1.5) < 0.001,
                "Front camera Live View is exact 3:2 (1.500:1) landscape and never rotated to 3:4 portrait"
            )
        }
        
        // 10b. Verify cropToLandscapeThreeByTwo on 4:3 (4032x3024 -> 4032x2688), 16:9 (1920x1080 -> 1620x1080), and 3:2 (3504x2336 -> 3504x2336)
        let raw4x3PhotoCG = makeSolidOrBorderCGImage(width: 400, height: 300, fillRGBA: (50, 100, 200, 255))
        let cropped4x3CG = BackdropCompositorService.cropToLandscapeThreeByTwo(raw4x3PhotoCG)
        assertEqual(cropped4x3CG.width, 400, "4:3 photo preserves full width (400)")
        assertEqual(cropped4x3CG.height, 267, "4:3 photo center-crops height to 3:2 (267)")
        
        let raw16x9CG = makeSolidOrBorderCGImage(width: 320, height: 180, fillRGBA: (50, 100, 200, 255))
        let cropped16x9CG = BackdropCompositorService.cropToLandscapeThreeByTwo(raw16x9CG)
        assertEqual(cropped16x9CG.width, 270, "16:9 frame center-crops width to 3:2 (270)")
        assertEqual(cropped16x9CG.height, 180, "16:9 frame preserves full height (180)")
        
        // 10c. Verify GIFService.createGIF produces 3:2 animated GIF frames even when fed 4:3 source images
        let raw4x3GIFSourceURL = qaRoot.appendingPathComponent("raw_4x3_gif_input.jpg")
        try UIImage(cgImage: raw4x3PhotoCG).jpegData(compressionQuality: 0.92)!.write(to: raw4x3GIFSourceURL)
        if let gif3x2URL = GIFService.createGIF(
            from: [raw4x3GIFSourceURL.absoluteString, raw4x3GIFSourceURL.absoluteString],
            frameDuration: 0.25,
            backdrop: magazine ?? .none,
            additionalSearchDirectories: [sampleBackdropsDir],
            customMaskProvider: { _ in maskCI }
        ),
           let gif3x2Src = CGImageSourceCreateWithURL(gif3x2URL as CFURL, nil),
           let gif3x2Frame = CGImageSourceCreateImageAtIndex(gif3x2Src, 0, nil) {
            let gifAspect = Double(gif3x2Frame.width) / Double(gif3x2Frame.height)
            assertTrue(
                abs(gifAspect - 1.5) < 0.01,
                String(format: "GIFService outputs 3:2 aspect ratio frames (%dx%d, ratio=%.3f)", gif3x2Frame.width, gif3x2Frame.height, gifAspect)
            )
            let fittedGIFOn4x3 = LiveView.fittedRect(
                forImageSize: CGSize(width: gif3x2Frame.width, height: gif3x2Frame.height),
                inContainerSize: iPad4x3Screen
            )
            assertTrue(
                abs(fittedGIFOn4x3.width - iPad4x3Screen.width) < 0.01 &&
                abs(fittedGIFOn4x3.minX) < 0.01 &&
                fittedGIFOn4x3.minY > 50.0,
                String(format: "3:2 GIF on 4:3 iPad spans 100%% width (left/right bars=0pt, top/bottom bars=%.1fpt)", fittedGIFOn4x3.minY)
            )
            try? fm.removeItem(at: gif3x2URL)
        } else {
            assertTrue(false, "Failed to verify 3:2 GIF output")
        }
        
        // 10d. Verify both Sony 3:2 (1024x680) and iPad 3:2 (1440x960) frames on both 4:3 (1366x1024) and 11" (1194x834) iPads
        //      have 0pt left/right bars and top/bottom black bars only.
        for streamSize in [CGSize(width: 1024, height: 680), CGSize(width: 1440, height: 960), CGSize(width: 3504, height: 2336)] {
            for screen in [iPad4x3Screen, iPad11ScreenSize] {
                let fitted = LiveView.fittedRect(forImageSize: streamSize, inContainerSize: screen)
                assertTrue(
                    abs(fitted.width - screen.width) < 0.01 &&
                    fitted.height < screen.height &&
                    abs(fitted.minX) < 0.01 &&
                    fitted.minY > 15.0,
                    String(format: "3:2 frame (%.0fx%.0f) on %.0fx%.0f iPad spans 100%% width (minX=%.1fpt, top/bottom bar=%.1fpt)", streamSize.width, streamSize.height, screen.width, screen.height, fitted.minX, fitted.minY)
                )
            }
        }
        
        // 11. Numeric Prefix Stripping in Backdrop Display Names (Carousel & Settings)
        assertEqual(
            BackdropManager.humanizeDisplayName(from: BackdropManager.stripRoleSuffix(from: "101_snowy_mountains_bg")),
            "Snowy Mountains",
            "101_snowy_mountains_bg.jpg displays as 'Snowy Mountains' (omits prepended 101_)"
        )
        assertEqual(
            BackdropManager.humanizeDisplayName(from: BackdropManager.stripRoleSuffix(from: "301_mars_bg")),
            "Mars",
            "301_mars_bg.jpg displays as 'Mars' (omits prepended 301_)"
        )
        assertEqual(
            BackdropManager.humanizeDisplayName(from: BackdropManager.stripRoleSuffix(from: "snowy_mountains_bg")),
            "Snowy Mountains",
            "Un-prefixed snowy_mountains_bg.jpg displays as 'Snowy Mountains' without modification"
        )
        assertEqual(
            BackdropManager.humanizeDisplayName(from: BackdropManager.stripRoleSuffix(from: "Eiffel Tower_bg")),
            "Eiffel Tower",
            "Un-prefixed Eiffel Tower_bg.jpg preserves capitalization without modification"
        )
        assertEqual(
            BackdropManager.humanizeDisplayName(from: BackdropManager.stripRoleSuffix(from: "304_levis_stadium_niners_bg")),
            "Levis Stadium Niners",
            "304_levis_stadium_niners_bg.jpg displays as 'Levis Stadium Niners'"
        )
    }
    
    // MARK: - Simulated Email Sharing & Spotty Wi-Fi Queue QA Suite
    
    final class MockEmailTransport: EmailTransport, @unchecked Sendable {
        nonisolated private let lock = NSLock()
        nonisolated(unsafe) private var _recordedRequests: [EmailDeliveryRequest] = []
        nonisolated(unsafe) var simulatedLatencySec: TimeInterval = 0.0
        nonisolated(unsafe) var outcomeHandler: (@Sendable (EmailDeliveryRequest, Int) -> EmailSendOutcome)? = nil
        nonisolated(unsafe) private var perJobAttemptCounter: [UUID: Int] = [:]
        
        nonisolated var recordedRequests: [EmailDeliveryRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _recordedRequests
        }
        
        nonisolated func reset() {
            lock.lock()
            defer { lock.unlock() }
            _recordedRequests.removeAll()
            perJobAttemptCounter.removeAll()
            outcomeHandler = nil
            simulatedLatencySec = 0.0
        }
        
        nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome {
            let (latency, attemptNum, handler): (TimeInterval, Int, (@Sendable (EmailDeliveryRequest, Int) -> EmailSendOutcome)?) = lock.withLock {
                _recordedRequests.append(request)
                let nextAttempt = (perJobAttemptCounter[request.jobID] ?? 0) + 1
                perJobAttemptCounter[request.jobID] = nextAttempt
                return (simulatedLatencySec, nextAttempt, outcomeHandler)
            }
            
            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            }
            
            if let handler = handler {
                return handler(request, attemptNum)
            }
            return .sent(providerMessageID: "mock_msg_\(request.jobID.uuidString)")
        }
    }
    
    private static func runEmailSharingAndQueueQATests() async throws {
        print("\n--- EMAIL SHARING & OFFLINE/SPOTTY WI-FI QUEUE QA ---")
        
        let fm = FileManager.default
        let qaEmailRoot = fm.temporaryDirectory.appendingPathComponent("qa_email_suite_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: qaEmailRoot, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: qaEmailRoot)
        }
        
        // 1. Email Validation & Domain Quick-Tap Chips
        assertTrue(EmailQueueService.isValidEmail("guest@gmail.com"), "Valid standard email accepted")
        assertTrue(EmailQueueService.isValidEmail("first.last+booth@sub.domain.co.uk"), "Valid subdomain + tag email accepted")
        assertTrue(!EmailQueueService.isValidEmail(""), "Empty email rejected")
        assertTrue(!EmailQueueService.isValidEmail("notanemail"), "Missing @ rejected")
        assertTrue(!EmailQueueService.isValidEmail("@gmail.com"), "Missing local part rejected")
        assertTrue(!EmailQueueService.isValidEmail("user@"), "Missing domain rejected")
        assertTrue(!EmailQueueService.isValidEmail("user@domain"), "Missing TLD dot rejected")
        assertTrue(!EmailQueueService.isValidEmail("user@domain..com"), "Double dot in domain rejected")
        assertTrue(!EmailQueueService.isValidEmail("user name@gmail.com"), "Whitespace inside email rejected")
        
        assertEqual(
            EmailSharingView.applyDomainShortcut("@gmail.com", to: "alex"),
            "alex@gmail.com",
            "Domain chip appends @gmail.com when no @ is present"
        )
        assertEqual(
            EmailSharingView.applyDomainShortcut("@icloud.com", to: "alex@gm"),
            "alex@icloud.com",
            "Domain chip replaces partial @gm suffix with @icloud.com"
        )
        
        // 2. HTML Footer & Hyperlink Formatting ("here" linked to QR code URL)
        let htmlYearOnly = EmailQueueService.buildEmailHTML(galleryURLString: "https://www.joshal.com/2026")
        assertTrue(
            htmlYearOnly.contains("All full resolution photos can be downloaded <a href=\"https://www.joshal.com/2026\">here</a> a day or two after the event."),
            "HTML email includes exact footer with 'here' hyperlinked to https://www.joshal.com/2026"
        )
        let htmlWithEvent = EmailQueueService.buildEmailHTML(galleryURLString: "https://www.joshal.com/2026/holiday-gala")
        assertTrue(
            htmlWithEvent.contains("All full resolution photos can be downloaded <a href=\"https://www.joshal.com/2026/holiday-gala\">here</a> a day or two after the event."),
            "HTML email includes exact footer with 'here' hyperlinked to https://www.joshal.com/2026/holiday-gala"
        )
        let htmlSchemeless = EmailQueueService.buildEmailHTML(galleryURLString: "www.joshal.com/2026/party")
        assertTrue(
            htmlSchemeless.contains("<a href=\"https://www.joshal.com/2026/party\">here</a>"),
            "Schemeless gallery URL automatically normalizes to https:// in hyperlink"
        )
        
        // 2B. Media-Tailored Body & Description (Photos vs. GIF vs. Both)
        assertEqual(
            EmailQueueService.sessionAttachmentDescription(for: ["photo_1.jpg", "photo_2.jpg"]),
            "Your photos from your session are attached to this email.",
            "Photos-only session uses 'Your photos from your session are attached to this email.'"
        )
        assertEqual(
            EmailQueueService.sessionAttachmentDescription(for: ["photobooth_animation.gif"]),
            "Your gif from your session are attached to this email.",
            "GIF-only session uses 'Your gif from your session are attached to this email.'"
        )
        let htmlGifOnly = EmailQueueService.buildEmailHTML(galleryURLString: "https://www.joshal.com/2026", mediaOrFilenames: ["anim.gif"])
        let textGifOnly = EmailQueueService.buildEmailPlainText(galleryURLString: "https://www.joshal.com/2026", mediaOrFilenames: ["anim.gif"])
        assertTrue(
            htmlGifOnly.contains("Your gif from your session are attached to this email.") &&
            htmlGifOnly.contains("All full resolution gifs can be downloaded") &&
            htmlGifOnly.contains("Share → Save Image") &&
            textGifOnly.contains("Share -> Save Image"),
            "GIF-only email contains tailored GIF description, footer, and mobile saving instructions (Share -> Save Image)"
        )
        let htmlPhotosOnly = EmailQueueService.buildEmailHTML(galleryURLString: "https://www.joshal.com/2026", mediaOrFilenames: ["p1.jpg"])
        let textPhotosOnly = EmailQueueService.buildEmailPlainText(galleryURLString: "https://www.joshal.com/2026", mediaOrFilenames: ["p1.jpg"])
        assertTrue(
            htmlPhotosOnly.contains("Your photos from your session are attached to this email.") &&
            htmlPhotosOnly.contains("All full resolution photos can be downloaded") &&
            !htmlPhotosOnly.contains("Save Image") &&
            !textPhotosOnly.contains("Save Image"),
            "Photos-only email contains tailored Photos description and footer without GIF saving instructions"
        )
        
        // 3. Online vs. Offline Guest Confirmation Copy
        let onlineCopy = EmailQueueService.confirmationMessage(forEmail: "guest@gmail.com", isOnline: true, mediaOrFilenames: ["p.jpg"])
        let onlineGifCopy = EmailQueueService.confirmationMessage(forEmail: "guest@gmail.com", isOnline: true, mediaOrFilenames: ["a.gif"])
        let offlineCopy = EmailQueueService.confirmationMessage(forEmail: "guest@gmail.com", isOnline: false, mediaOrFilenames: ["p.jpg"])
        assertTrue(
            onlineCopy.isOnline && onlineCopy.title == "Sending Your Photos!" && onlineCopy.subtitle.contains("Your photos are being emailed"),
            "Online photos confirmation copy confirms immediate background sending for photos"
        )
        assertTrue(
            onlineGifCopy.isOnline && onlineGifCopy.title == "Sending Your GIF!" && onlineGifCopy.subtitle.contains("Your GIF is being emailed"),
            "Online GIF confirmation copy confirms immediate background sending for GIF"
        )
        assertTrue(
            !offlineCopy.isOnline &&
            offlineCopy.subtitle.lowercased().contains("offline") &&
            offlineCopy.subtitle.lowercased().contains("connects to wi-fi"),
            "Offline confirmation copy explicitly states iPad is offline and email will arrive when iPad connects to Wi-Fi"
        )
        
        // 4. Scenario A: Online Mode — Instant Non-Blocking Enqueue (< 25ms), Immediate /tmp Cleanup Independence, & Post-Send Disk Cleanup
        let scenarioADir = qaEmailRoot.appendingPathComponent("scenarioA", isDirectory: true)
        let mockTransportA = MockEmailTransport()
        mockTransportA.simulatedLatencySec = 0.12 // 120ms network upload latency
        
        let serviceA = EmailQueueService(
            customDirectoryURL: scenarioADir,
            transport: mockTransportA,
            useSystemNetworkMonitor: false,
            initialNetworkConnected: true,
            networkDebounceSec: 0.0,
            baseBackoffSec: 0.05,
            maxBackoffSec: 1.0,
            apiKeyOverride: "re_test_key_123",
            fromAddressOverride: "Photobooth <photos@joshal.com>",
            subjectOverride: "Your Photobooth Photos"
        )
        
        let tmpPhoto1 = qaEmailRoot.appendingPathComponent("sony_\(UUID().uuidString).jpg")
        let tmpPhoto2 = qaEmailRoot.appendingPathComponent("sony_\(UUID().uuidString).jpg")
        let tmpPhoto3 = qaEmailRoot.appendingPathComponent("sony_\(UUID().uuidString).jpg")
        let tmpGIF = qaEmailRoot.appendingPathComponent("\(UUID().uuidString).gif")
        let samplePhotoBytes1 = Data("JPEG_PAYLOAD_1".utf8)
        let samplePhotoBytes2 = Data("JPEG_PAYLOAD_2".utf8)
        let samplePhotoBytes3 = Data("JPEG_PAYLOAD_3".utf8)
        let sampleGIFBytes = Data("GIF89a_ANIMATED_PAYLOAD".utf8)
        try samplePhotoBytes1.write(to: tmpPhoto1)
        try samplePhotoBytes2.write(to: tmpPhoto2)
        try samplePhotoBytes3.write(to: tmpPhoto3)
        try sampleGIFBytes.write(to: tmpGIF)
        
        let enqueueStart = CFAbsoluteTimeGetCurrent()
        let queuedJobA = serviceA.enqueue(
            recipientEmail: "online.guest@gmail.com",
            mediaPaths: [tmpPhoto1.path, tmpPhoto2.path, tmpPhoto3.path, tmpGIF.path],
            galleryURLString: "https://www.joshal.com/2026/wedding"
        )
        let enqueueElapsedMs = (CFAbsoluteTimeGetCurrent() - enqueueStart) * 1000.0
        
        // Immediately delete the /tmp source files right after enqueue() returns (while the 120ms upload is still in flight)
        // to prove zero race condition when StateMachine transitions to .idle for the next photobooth user!
        try? fm.removeItem(at: tmpPhoto1)
        try? fm.removeItem(at: tmpPhoto2)
        try? fm.removeItem(at: tmpPhoto3)
        try? fm.removeItem(at: tmpGIF)
        
        assertTrue(queuedJobA != nil, "Scenario A: enqueue() returned valid EmailQueueItem")
        assertTrue(
            enqueueElapsedMs < 50.0,
            String(format: "Scenario A: enqueue() completed non-blockingly in %.2fms (< 50ms threshold, before 120ms network upload)", enqueueElapsedMs)
        )
        
        await serviceA.flushQueue()
        
        let requestsA = mockTransportA.recordedRequests
        assertEqual(requestsA.count, 1, "Scenario A: Exactly 1 email request transmitted")
        if let reqA = requestsA.first, let jobA = queuedJobA {
            assertEqual(reqA.to, "online.guest@gmail.com", "Scenario A: Recipient matches")
            assertEqual(reqA.idempotencyKey, jobA.id.uuidString, "Scenario A: Idempotency-Key header matches job UUID")
            assertEqual(reqA.attachments.count, 4, "Scenario A: All 3 photos + 1 GIF attached despite immediate /tmp deletion")
            assertEqual(reqA.attachments[0].data, samplePhotoBytes1, "Scenario A: Photo 1 bytes intact")
            assertEqual(reqA.attachments[3].data, sampleGIFBytes, "Scenario A: GIF bytes intact")
            assertEqual(reqA.attachments[3].contentType, "image/gif", "Scenario A: GIF contentType is image/gif")
            assertTrue(
                reqA.htmlBody.contains("<a href=\"https://www.joshal.com/2026/wedding\">here</a>"),
                "Scenario A: Transmitted HTML body contains hyperlinked 'here' footer"
            )
            let jobADir = scenarioADir.appendingPathComponent(jobA.id.uuidString, isDirectory: true)
            assertTrue(!fm.fileExists(atPath: jobADir.path), "Scenario A: Local job media folder deleted immediately after 200 OK")
        }
        let statsA = serviceA.currentStatsSnapshot()
        assertEqual(statsA.pending, 0, "Scenario A: 0 pending items after delivery")
        assertEqual(statsA.sent, 1, "Scenario A: totalSentCount incremented to 1")
        
        // 5. Scenario B: Offline Mode — Multi-Session Queuing, URL Snapshotting, Reboot Persistence, & Later Wi-Fi Auto-Flush
        let scenarioBDir = qaEmailRoot.appendingPathComponent("scenarioB", isDirectory: true)
        let mockTransportB = MockEmailTransport()
        
        var serviceB: EmailQueueService? = EmailQueueService(
            customDirectoryURL: scenarioBDir,
            transport: mockTransportB,
            useSystemNetworkMonitor: false,
            initialNetworkConnected: false, // Offline venue
            networkDebounceSec: 0.01,
            baseBackoffSec: 0.05,
            maxBackoffSec: 1.0,
            apiKeyOverride: "re_test_key_123"
        )
        
        let offlineEmails = [
            ("alice@android.com", "https://www.joshal.com/2026"),
            ("bob@pixel.com", "https://www.joshal.com/2026/birthday"),
            ("carol@galaxy.com", "https://www.joshal.com/2026/corporate")
        ]
        for (idx, entry) in offlineEmails.enumerated() {
            let pURL = qaEmailRoot.appendingPathComponent("offline_\(idx).jpg")
            try Data("OFFLINE_IMG_\(idx)".utf8).write(to: pURL)
            let queued = serviceB?.enqueue(
                recipientEmail: entry.0,
                mediaPaths: [pURL.path],
                galleryURLString: entry.1
            )
            assertTrue(queued != nil, "Scenario B: Queued offline session \(idx + 1) (\(entry.0))")
            // Immediately delete /tmp file as booth resets for next guest
            try? fm.removeItem(at: pURL)
        }
        
        assertEqual(mockTransportB.recordedRequests.count, 0, "Scenario B: Zero network requests attempted while iPad is offline")
        assertEqual(serviceB?.currentStatsSnapshot().pending, 3, "Scenario B: 3 jobs waiting in offline queue")
        
        // Simulate iPad power cycle / app restart while still offline
        serviceB = nil
        let reloadedServiceB = EmailQueueService(
            customDirectoryURL: scenarioBDir,
            transport: mockTransportB,
            useSystemNetworkMonitor: false,
            initialNetworkConnected: false,
            networkDebounceSec: 0.01,
            baseBackoffSec: 0.05,
            maxBackoffSec: 1.0,
            apiKeyOverride: "re_test_key_123"
        )
        assertEqual(reloadedServiceB.currentStatsSnapshot().pending, 3, "Scenario B: All 3 offline jobs survived simulated iPad reboot")
        
        // Now simulate iPad connecting to home Wi-Fi after the event
        reloadedServiceB.setSimulatedNetworkConnected(true)
        try? await Task.sleep(nanoseconds: 40_000_000) // Allow 10ms debounce to fire
        await reloadedServiceB.flushQueue()
        
        let requestsB = mockTransportB.recordedRequests
        assertEqual(requestsB.count, 3, "Scenario B: All 3 queued emails automatically flushed upon Wi-Fi connection")
        if requestsB.count == 3 {
            assertEqual(requestsB[0].to, "alice@android.com", "Scenario B: FIFO order preserved (1/3)")
            assertEqual(requestsB[1].to, "bob@pixel.com", "Scenario B: FIFO order preserved (2/3)")
            assertEqual(requestsB[2].to, "carol@galaxy.com", "Scenario B: FIFO order preserved (3/3)")
            assertTrue(
                requestsB[0].htmlBody.contains("<a href=\"https://www.joshal.com/2026\">here</a>") &&
                requestsB[1].htmlBody.contains("<a href=\"https://www.joshal.com/2026/birthday\">here</a>") &&
                requestsB[2].htmlBody.contains("<a href=\"https://www.joshal.com/2026/corporate\">here</a>"),
                "Scenario B: Each queued email preserved its snapshotted event gallery URL"
            )
        }
        assertEqual(reloadedServiceB.currentStatsSnapshot().pending, 0, "Scenario B: Queue is empty after flush")
        assertEqual(reloadedServiceB.currentStatsSnapshot().sent, 3, "Scenario B: totalSentCount == 3")
        
        // 6. Scenario C: Spotty Wi-Fi — Mid-Upload Drops, Exponential Backoff, Idempotency Keys, Flip-Flopping & Crash Recovery
        let scenarioCDir = qaEmailRoot.appendingPathComponent("scenarioC", isDirectory: true)
        let mockTransportC = MockEmailTransport()
        
        // C1 & C2: Fail attempts 1 & 2 with transient network drop, succeed on attempt 3
        mockTransportC.outcomeHandler = { req, attempt in
            if req.to == "spotty@venue.com" && attempt < 3 {
                return .transientFailure(reason: "URLError(-1005): Network connection was lost", retryAfterSec: 0.04)
            }
            if req.to == "bad-syntax-on-server@invalid.tld" {
                return .permanentRecipientFailure(reason: "HTTP 422: Invalid recipient domain")
            }
            return .sent(providerMessageID: "msg_\(req.jobID.uuidString)_attempt_\(attempt)")
        }
        
        let serviceC = EmailQueueService(
            customDirectoryURL: scenarioCDir,
            transport: mockTransportC,
            useSystemNetworkMonitor: false,
            initialNetworkConnected: false,
            networkDebounceSec: 0.01,
            baseBackoffSec: 0.04,
            maxBackoffSec: 0.5,
            apiKeyOverride: "re_test_key_123"
        )
        
        let spottyImg = qaEmailRoot.appendingPathComponent("spotty.jpg")
        try Data("SPOTTY_IMAGE_DATA".utf8).write(to: spottyImg)
        let spottyJob = serviceC.enqueue(
            recipientEmail: "spotty@venue.com",
            mediaPaths: [spottyImg.path],
            galleryURLString: "https://www.joshal.com/2026/spotty"
        )
        let badJob = serviceC.enqueue(
            recipientEmail: "bad-syntax-on-server@invalid.tld",
            mediaPaths: [spottyImg.path],
            galleryURLString: "https://www.joshal.com/2026/spotty"
        )
        let afterBadJob = serviceC.enqueue(
            recipientEmail: "after.bad@venue.com",
            mediaPaths: [spottyImg.path],
            galleryURLString: "https://www.joshal.com/2026/spotty"
        )
        try? fm.removeItem(at: spottyImg)
        
        assertTrue(spottyJob != nil && badJob != nil && afterBadJob != nil, "Scenario C: Enqueued spotty, bad, and valid follow-up jobs")
        
        // Simulate rapid Wi-Fi flip-flopping (concurrency storm) followed by stable connection
        for i in 0..<6 {
            serviceC.setSimulatedNetworkConnected(i % 2 == 0)
        }
        serviceC.setSimulatedNetworkConnected(true)
        
        // Attempt 1 runs and fails for spotty@venue.com, while bad-syntax marks failedPermanent and after.bad succeeds!
        await serviceC.flushQueue(ignoreBackoff: true)
        // Attempt 2 runs and fails for spotty@venue.com
        await serviceC.flushQueue(ignoreBackoff: true)
        // Attempt 3 runs and succeeds for spotty@venue.com
        await serviceC.flushQueue(ignoreBackoff: true)
        
        let spottyAttempts = mockTransportC.recordedRequests.filter { $0.to == "spotty@venue.com" }
        let afterBadAttempts = mockTransportC.recordedRequests.filter { $0.to == "after.bad@venue.com" }
        assertEqual(spottyAttempts.count, 3, "Scenario C1: Spotty Wi-Fi job retried 3 times until 200 OK")
        assertEqual(afterBadAttempts.count, 1, "Scenario C3/C5: Valid job after failed job sent exactly once despite Wi-Fi flip-flopping")
        if spottyAttempts.count == 3, let spottyID = spottyJob?.id.uuidString {
            assertTrue(
                spottyAttempts.allSatisfy { $0.idempotencyKey == spottyID },
                "Scenario C2: All 3 retry attempts sent identical Idempotency-Key (\(spottyID)) to prevent duplicate emails"
            )
        }
        let statsC = serviceC.currentStatsSnapshot()
        assertEqual(statsC.pending, 0, "Scenario C: 0 pending jobs remaining")
        assertEqual(statsC.failed, 1, "Scenario C5: 1 permanent recipient failure recorded without blocking queue")
        assertEqual(statsC.sent, 2, "Scenario C: 2 valid jobs delivered")
        
        // C4: Simulate crash mid-send recovery (job persisted on disk with status == .sending)
        let crashDir = qaEmailRoot.appendingPathComponent("scenarioCrash", isDirectory: true)
        try fm.createDirectory(at: crashDir, withIntermediateDirectories: true)
        let crashedJobID = UUID()
        let crashedJobFolder = crashDir.appendingPathComponent(crashedJobID.uuidString, isDirectory: true)
        try fm.createDirectory(at: crashedJobFolder, withIntermediateDirectories: true)
        try Data("CRASH_RECOVERY_JPEG".utf8).write(to: crashedJobFolder.appendingPathComponent("photobooth_photo_1.jpg"))
        
        let crashedDoc = EmailQueueManifestDocument(
            schemaVersion: 1,
            totalSentCount: 0,
            items: [
                EmailQueueItem(
                    id: crashedJobID,
                    recipientEmail: "recovered@crash.com",
                    galleryURLString: "https://www.joshal.com/2026",
                    subject: "Recovered",
                    attachmentFilenames: ["photobooth_photo_1.jpg"],
                    createdAt: Date().addingTimeInterval(-120),
                    status: .sending, // Left in .sending when app crashed
                    attemptCount: 1,
                    nextAttemptAt: Date().addingTimeInterval(-60),
                    lastError: nil
                )
            ]
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(crashedDoc).write(to: crashDir.appendingPathComponent(EmailQueueManifestDocument.defaultFilename))
        
        let mockTransportCrash = MockEmailTransport()
        let recoveredService = EmailQueueService(
            customDirectoryURL: crashDir,
            transport: mockTransportCrash,
            useSystemNetworkMonitor: false,
            initialNetworkConnected: true,
            networkDebounceSec: 0.0,
            apiKeyOverride: "re_test_key_123"
        )
        await recoveredService.flushQueue()
        assertEqual(mockTransportCrash.recordedRequests.count, 1, "Scenario C4: Interrupted .sending job recovered to .pending on init and sent")
        assertEqual(recoveredService.currentStatsSnapshot().sent, 1, "Scenario C4: Recovered job marked sent")
        
        // C6: StateMachine transition verification (.sharingPrompt -> .emailSharing -> .sharingPrompt -> .emailSharing -> .idle)
        let mockCam = MockCameraClient()
        let sm = StateMachine(cameraService: mockCam)
        sm.transition(to: .sharingPrompt(images: ["file:///tmp/test.jpg"]))
        assertEqual(sm.state, .sharingPrompt(images: ["file:///tmp/test.jpg"]), "StateMachine enters .sharingPrompt")
        sm.selectEmailSharing()
        assertEqual(sm.state, .emailSharing(images: ["file:///tmp/test.jpg"]), "StateMachine.selectEmailSharing() transitions to .emailSharing")
        sm.returnToSharingPrompt()
        assertEqual(sm.state, .sharingPrompt(images: ["file:///tmp/test.jpg"]), "StateMachine.returnToSharingPrompt() returns to .sharingPrompt when guest taps Back")
        sm.selectEmailSharing()
        sm.skipSharing()
        assertEqual(sm.state, .idle, "StateMachine.skipSharing() returns from .emailSharing to .idle")
        
        // C7: ResendEmailTransport HTTP Protocol Verification (200 JSON, 200 HTML Captive Portal Rejection, 429 Retry-After, 401 Config Pause, 422 Permanent Failure)
        let httpTransport = ResendEmailTransport(protocolClasses: [QAMockEmailHTTPURLProtocol.self])
        let sampleReq = EmailDeliveryRequest(
            jobID: UUID(),
            idempotencyKey: "idem-test-12345",
            from: "Photobooth <onboarding@resend.dev>",
            to: "guest@joshal.com",
            subject: "Your Photobooth Photos",
            htmlBody: EmailQueueService.buildEmailHTML(galleryURLString: "https://www.joshal.com/2026/gala"),
            textBody: EmailQueueService.buildEmailPlainText(galleryURLString: "https://www.joshal.com/2026/gala"),
            attachments: [
                EmailAttachmentPayload(filename: "photobooth_photo_1.jpg", contentType: "image/jpeg", data: Data("JPEG_DATA".utf8)),
                EmailAttachmentPayload(filename: "photobooth_animation.gif", contentType: "image/gif", data: Data("GIF89a_DATA".utf8))
            ],
            apiKey: "re_live_verification_key"
        )
        
        // 1) Valid 200 OK JSON response
        QAMockEmailHTTPURLProtocol.responseProvider = { req in
            let authHeader = req.value(forHTTPHeaderField: "Authorization") ?? ""
            let idemHeader = req.value(forHTTPHeaderField: "Idempotency-Key") ?? ""
            guard authHeader == "Bearer re_live_verification_key", idemHeader == "idem-test-12345" else {
                return (400, ["Content-Type": "application/json"], Data("{\"message\":\"Missing headers\"}".utf8))
            }
            return (200, ["Content-Type": "application/json"], Data("{\"id\":\"re_msg_verified_001\"}".utf8))
        }
        let outcome200 = await httpTransport.sendEmail(sampleReq)
        if case .sent(let msgID) = outcome200 {
            assertEqual(msgID, "re_msg_verified_001", "ResendEmailTransport parses 200 OK JSON id and sends Bearer + Idempotency-Key headers")
        } else {
            assertTrue(false, "ResendEmailTransport expected .sent for 200 OK JSON, got \(outcome200)")
        }
        
        // 2) Captive Portal 200 OK returning text/html login splash page (must NOT mark email as sent!)
        QAMockEmailHTTPURLProtocol.responseProvider = { _ in
            return (200, ["Content-Type": "text/html; charset=utf-8"], Data("<html><body>Welcome to Venue Guest Wi-Fi! Please sign in.</body></html>".utf8))
        }
        let outcomeCaptive = await httpTransport.sendEmail(sampleReq)
        if case .transientFailure(let reason, _) = outcomeCaptive {
            assertTrue(reason.lowercased().contains("html") || reason.lowercased().contains("captive"), "ResendEmailTransport rejects 200 OK text/html captive portal response as transientFailure: \(reason)")
        } else {
            assertTrue(false, "ResendEmailTransport must reject 200 OK text/html captive portal, got \(outcomeCaptive)")
        }
        
        // 3) HTTP 429 Rate Limit with Retry-After header
        QAMockEmailHTTPURLProtocol.responseProvider = { _ in
            return (429, ["Content-Type": "application/json", "Retry-After": "37"], Data("{\"message\":\"Rate limit exceeded\"}".utf8))
        }
        let outcome429 = await httpTransport.sendEmail(sampleReq)
        if case .transientFailure(_, let retryAfter) = outcome429 {
            assertEqual(retryAfter, 37.0, "ResendEmailTransport extracts Retry-After header (37s) on HTTP 429")
        } else {
            assertTrue(false, "ResendEmailTransport expected .transientFailure on HTTP 429, got \(outcome429)")
        }
        
        // 4) HTTP 401 Unauthorized -> .configurationPaused (keeps job pending so user can fix API key in Settings)
        QAMockEmailHTTPURLProtocol.responseProvider = { _ in
            return (401, ["Content-Type": "application/json"], Data("{\"message\":\"Invalid API key\"}".utf8))
        }
        let outcome401 = await httpTransport.sendEmail(sampleReq)
        if case .configurationPaused = outcome401 {
            assertTrue(true, "ResendEmailTransport classifies HTTP 401 as .configurationPaused")
        } else {
            assertTrue(false, "ResendEmailTransport expected .configurationPaused on HTTP 401, got \(outcome401)")
        }
        
        // 5) HTTP 422 Unprocessable Entity -> .permanentRecipientFailure
        QAMockEmailHTTPURLProtocol.responseProvider = { _ in
            return (422, ["Content-Type": "application/json"], Data("{\"message\":\"Invalid 'to' email address\"}".utf8))
        }
        let outcome422 = await httpTransport.sendEmail(sampleReq)
        if case .permanentRecipientFailure(let reason) = outcome422 {
            assertTrue(reason.contains("422"), "ResendEmailTransport classifies HTTP 422 as .permanentRecipientFailure: \(reason)")
        } else {
            assertTrue(false, "ResendEmailTransport expected .permanentRecipientFailure on HTTP 422, got \(outcome422)")
        }
        
        // C8: GmailSMTPTransport MIME Builder & Unconfigured Credential Warning
        let (parsedEmail, parsedHeader) = GmailSMTPTransport.parseSenderAddress("Photobooth <joshal7@gmail.com>")
        assertEqual(parsedEmail, "joshal7@gmail.com", "GmailSMTPTransport extracts bare sender email from display header")
        assertEqual(parsedHeader, "Photobooth <joshal7@gmail.com>", "GmailSMTPTransport preserves display From header")
        
        let mimeData = GmailSMTPTransport.buildMIMEMessage(
            sampleReq,
            envelopeSender: parsedEmail,
            formattedFromHeader: parsedHeader
        )
        let mimeString = String(data: mimeData, encoding: .utf8) ?? ""
        assertTrue(
            mimeString.contains("From: Photobooth <joshal7@gmail.com>\r\n") &&
            mimeString.contains("To: <guest@joshal.com>\r\n") &&
            mimeString.contains("Content-Type: multipart/mixed;") &&
            mimeString.contains("filename=\"photobooth_photo_1.jpg\"") &&
            mimeString.contains("filename=\"photobooth_animation.gif\"") &&
            mimeString.hasSuffix("\r\n.\r\n"),
            "GmailSMTPTransport builds standards-compliant RFC 5322 multipart/mixed MIME payload ending with CRLF.CRLF"
        )
        
        let unconfiguredCopy = EmailQueueService.confirmationMessage(
            forEmail: "guest@gmail.com",
            isOnline: true,
            isConfigured: false
        )
        assertTrue(
            !unconfiguredCopy.isConfigured && unconfiguredCopy.subtitle.lowercased().contains("settings"),
            "Unconfigured email confirmation explicitly warns user to enter Gmail App Password or Resend Key in Settings"
        )
        
        // C9: Post-email confirmation screen timing (1.5s online vs 2.5s offline +1s)
        assertEqual(
            EmailQueueService.postSubmitDismissDurationNanoseconds(isOnline: true, isConfigured: true),
            1_500_000_000,
            "Post-email confirmation screen stays at 1.5s when online ('Sending now')"
        )
        assertEqual(
            EmailQueueService.postSubmitDismissDurationNanoseconds(isOnline: false, isConfigured: true),
            2_500_000_000,
            "Post-email confirmation screen adds 1s (2.5s total) when offline ('Saved for Wi-Fi Delivery')"
        )
        
        // C10: Animated GIF email normalization (1620x1080 -> 960x640 multi-frame GIF with zero black-dot delta corruption)
        let rawFourFrameGIFData: Data? = {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let buf = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(buf, UTType.gif.identifier as CFString, 4, nil) else { return nil }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
            for idx in 0..<4 {
                guard let ctx = CGContext(data: nil, width: 1620, height: 1080, bitsPerComponent: 8, bytesPerRow: 1620 * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
                // Static warm background + moving subject rectangle so delta frames exercise unchanged background pixels
                ctx.setFillColor(red: 0.85, green: 0.75, blue: 0.60, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: 1620, height: 1080))
                ctx.setFillColor(red: 0.30 + CGFloat(idx) * 0.15, green: 0.45, blue: 0.75, alpha: 1.0)
                ctx.fill(CGRect(x: 300 + idx * 120, y: 200, width: 400, height: 500))
                guard let cg = ctx.makeImage() else { return nil }
                CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 0.45]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else { return nil }
            return buf as Data
        }()
        if let rawGIF = rawFourFrameGIFData {
            let normalizedGIF = EmailQueueService.normalizeGIFAttachmentForEmail(rawGIF)
            if let gifSrc = CGImageSourceCreateWithData(normalizedGIF as CFData, nil) {
                let count = CGImageSourceGetCount(gifSrc)
                assertEqual(count, 4, "Normalized email GIF preserves all 4 animated frames")
                let f0Props = CGImageSourceCopyPropertiesAtIndex(gifSrc, 0, nil) as? [CFString: Any]
                let w = f0Props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = f0Props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                let gifDict = f0Props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = gifDict?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
                let containerProps = CGImageSourceCopyProperties(gifSrc, nil) as? [CFString: Any]
                let containerGIF = containerProps?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let loopCount = containerGIF?[kCGImagePropertyGIFLoopCount] as? Int ?? -1
                assertEqual(w, 960, "Normalized email GIF width is 960px (< 1000px mobile proxy threshold)")
                assertEqual(h, 640, "Normalized email GIF height is 640px (exact 3:2 landscape)")
                assertEqual(loopCount, 0, "Normalized email GIF preserves infinite LoopCount = 0")
                assertTrue(abs(delay - 0.45) < 0.02, "Normalized email GIF frame preserves DelayTime (0.45s)")
                
                var blackPixelCount = 0
                for frameIdx in 0..<count {
                    if let frameCG = CGImageSourceCreateImageAtIndex(gifSrc, frameIdx, nil),
                       let dp = frameCG.dataProvider?.data as Data? {
                        for p in stride(from: 0, to: dp.count, by: 4) {
                            if dp[p] < 10 && dp[p + 1] < 10 && dp[p + 2] < 10 {
                                blackPixelCount += 1
                            }
                        }
                    }
                }
                assertEqual(blackPixelCount, 0, "Normalized email GIF frames 1-4 have zero black-dot delta corruption pixels")
            } else {
                assertTrue(false, "Normalized email GIF data must be a valid CGImageSource")
            }
        }
        
        // 13. ConfigManager Default Consistency & GIFService Empty Input Guard
        let config = ConfigManager.shared
        let savedGIFPreviewDuration = config.gifPreviewDuration
        config.resetToDefaults()
        assertEqual(config.gifPreviewDuration, 6.0, "ConfigManager.resetToDefaults() sets gifPreviewDuration to 6.0 matching init()")
        config.gifPreviewDuration = savedGIFPreviewDuration
        
        let emptyGIFResult = GIFService.createGIF(from: [], frameDuration: 0.25)
        assertTrue(emptyGIFResult == nil, "GIFService.createGIF(from: []) returns nil cleanly without creating orphaned files")
        assertEqual(BackdropManager.normalizedID(from: "!!!"), "", "BackdropManager.normalizedID returns empty string for punctuation-only input")
        
        // 14. LocalCameraClient (iPad Mode) Multi-Frame GIF Capture Verification
        let localClient = LocalCameraClient()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        if let ctx = CGContext(data: nil, width: 1440, height: 960, bitsPerComponent: 8, bytesPerRow: 1440 * 4, space: colorSpace, bitmapInfo: bitmapInfo) {
            ctx.setFillColor(red: 0.55, green: 0.45, blue: 0.65, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: 1440, height: 960))
            if let testCG = ctx.makeImage() {
                localClient.seedLatestSubjectFrameForTesting(testCG)
                try await localClient.prepareForCapture(mode: .gif)
                var capturedLocalGIFURLs: [String] = []
                for _ in 0..<4 {
                    let urls = try await localClient.takePicture()
                    if let first = urls.first {
                        capturedLocalGIFURLs.append(first)
                    }
                }
                await localClient.finishCaptureSequence(mode: .gif)
                assertEqual(capturedLocalGIFURLs.count, 4, "LocalCameraClient (iPad mode) completes all 4 back-to-back GIF frame captures without stalling after frame 1")
                for urlStr in capturedLocalGIFURLs {
                    if let parsed = URL(string: urlStr) {
                        try? FileManager.default.removeItem(at: parsed)
                    }
                }
            }
        }
    }
}

private nonisolated final class QAMockEmailHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseProvider: ((URLRequest) -> (Int, [String: String], Data))?
    
    override nonisolated class func canInit(with request: URLRequest) -> Bool {
        true
    }
    
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }
    
    override nonisolated func startLoading() {
        guard let provider = Self.responseProvider, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (statusCode, headers, body) = provider(request)
        if let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override nonisolated func stopLoading() {}
}
#endif

