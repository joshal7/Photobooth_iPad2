import Foundation

/// Standard ISO 15740 & Sony Vendor-Extended PTP Opcodes
enum SonyPTPOpcode: UInt16, Sendable {
    case getObjectInfo               = 0x1008
    case getObject                   = 0x1009
    case sdioConnect                 = 0x9201
    case sdioGetExtDeviceInfo        = 0x9202
    case sdioSetExtDevicePropValue   = 0x9205
    case sdioControlDevice           = 0x9207
    case sdioGetAllExtDevicePropInfo = 0x9209
}

enum SonyPTPResponseCode: UInt16, Sendable {
    case ok                          = 0x2001
    case generalError                = 0x2002
    case operationNotSupported       = 0x2005
    case invalidObjectHandle         = 0x2009
    case accessDenied                = 0x200F
    case deviceBusy                  = 0x2019
}

enum SonyPTPPropertyCode: UInt16, Sendable {
    case focusFound                  = 0xD213 // UInt8: 1 = idle, 2 = focused
    case objectInMemory              = 0xD215 // UInt16: >= 0x8000 means image ready at 0xFFFFC001
    case batteryLevel                = 0xD218 // UInt8: battery %
    case liveViewStatus              = 0xD221 // UInt8: 1 = active
    case stillImageSaveDestination   = 0xD222 // UInt16: 0x0001 = PC, 0x0010 = Card, 0x0011 = PC+Card
    case liveViewSettingEffect       = 0xD231 // UInt8: 1 = Setting Effect ON, 2 = Setting Effect OFF (auto-expose Live View)
    case priorityMode                = 0xD25A // UInt8: 0 = Camera Priority, 1 = PC Application Priority
    case pcSaveImageSize             = 0xD268 // UInt8: 1 = Original, 2 = 2M
    case pcSaveImageFormat           = 0xD269 // UInt8: 1 = RAW+J, 2 = JPEG Only, 3 = RAW Only
    case shutterHalfRelease          = 0xD2C1 // UInt16: 2 = Press S1, 1 = Release S1
    case shutterRelease              = 0xD2C2 // UInt16: 2 = Press S2, 1 = Release S2
}

enum SonyPTPHostHandle: UInt32, Sendable {
    case capturedImageRAM            = 0xFFFFC001
    case liveViewFrameRAM            = 0xFFFFC002
}

enum SonySaveDestination: UInt16, Sendable {
    case pcOnly                      = 0x0001 // Skips SD card completely (used for GIF frames)
    case cameraOnly                  = 0x0010 // SD card only
    case pcAndCamera                 = 0x0011 // Archives Full-Res on SD card + transfers 2M JPEG to iPad
}

enum SonyTransferImageSize: UInt8, Sendable {
    case original                    = 0x01
    case twoMegapixel                = 0x02
}

struct SonyPTPPacket: Sendable {
    /// Builds a Little-Endian USB Still Image Capture Class (ISO 15740) Command Block Container.
    nonisolated static func buildCommand(
        opcode: SonyPTPOpcode,
        transactionID: UInt32,
        params: [UInt32] = []
    ) -> Data {
        let clampedParams = Array(params.prefix(5))
        let length = UInt32(12 + clampedParams.count * 4)
        let containerType: UInt16 = 0x0001 // Command Block
        
        var data = Data(capacity: Int(length))
        data.appendLittleEndian(length)
        data.appendLittleEndian(containerType)
        data.appendLittleEndian(opcode.rawValue)
        data.appendLittleEndian(transactionID)
        for param in clampedParams {
            data.appendLittleEndian(param)
        }
        return data
    }
    
    /// Builds a Little-Endian PTP Response Block Container (used by MockPTPTransport in unit tests).
    nonisolated static func buildResponse(
        code: SonyPTPResponseCode,
        transactionID: UInt32 = 1
    ) -> Data {
        var data = Data(capacity: 12)
        data.appendLittleEndian(UInt32(12))
        data.appendLittleEndian(UInt16(0x0003)) // Response Block
        data.appendLittleEndian(code.rawValue)
        data.appendLittleEndian(transactionID)
        return data
    }
    
    /// Parses the 16-bit PTP Response Code from an `ImageCaptureCore` `ptpResponseData` container.
    nonisolated static func parseResponseCode(from responseContainer: Data) -> UInt16? {
        guard responseContainer.count >= 8 else { return nil }
        return responseContainer.readUInt16LE(at: 6)
    }
    
    /// Extracts the embedded JPEG frame from a Sony `0xFFFFC002` Live View payload.
    /// Per Sony PTP specification, the first 4 bytes hold the little-endian offset to the JPEG SOI (`0xFF 0xD8`),
    /// with a fallback scan for SOI/EOI markers.
    nonisolated static func extractLiveViewJPEG(from payload: Data) -> Data? {
        guard payload.count > 16 else { return nil }
        
        // 1. Check 4-byte little-endian offset header
        if let headerOffset = payload.readUInt32LE(at: 0) {
            let offset = Int(headerOffset)
            if offset >= 4, offset + 2 < payload.count,
               payload[payload.startIndex + offset] == 0xFF,
               payload[payload.startIndex + offset + 1] == 0xD8 {
                let slice = payload.subdata(in: (payload.startIndex + offset)..<payload.endIndex)
                let eoi = Data([0xFF, 0xD9])
                if let eoiRange = slice.range(of: eoi, options: .backwards) {
                    return slice.subdata(in: slice.startIndex..<eoiRange.upperBound)
                }
                return slice
            }
        }
        
        // 2. Fallback: search for JPEG SOI (0xFF 0xD8) and EOI (0xFF 0xD9) after 4-byte header
        let searchRange = (payload.startIndex + 4)..<payload.endIndex
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])
        guard let soiRange = payload.range(of: soi, in: searchRange),
              let eoiRange = payload.range(of: eoi, options: .backwards, in: soiRange.lowerBound..<payload.endIndex) else {
            return nil
        }
        return payload.subdata(in: soiRange.lowerBound..<eoiRange.upperBound)
    }
    
    /// Parses `0xD215` (`ObjectInMemory`) current `UInt16` value from Sony's `0x9209` `SDIO_GetAllExtDevicePropInfo` blob.
    nonisolated static func parseObjectInMemory(from propBlob: Data) -> UInt16? {
        return parseUInt16Property(.objectInMemory, from: propBlob)
    }
    
    /// Scans Sony's `0x9209` property descriptor list for a specific `UInt16` DevicePropCode (`0xD2xx`)
    /// with DataType `0x0004` (`PTP_DTC_UINT16`).
    nonisolated static func parseUInt16Property(_ prop: SonyPTPPropertyCode, from propBlob: Data) -> UInt16? {
        guard propBlob.count >= 18 else { return nil }
        let codeLo = UInt8(prop.rawValue & 0xFF)
        let codeHi = UInt8((prop.rawValue >> 8) & 0xFF)
        let pattern = Data([codeLo, codeHi, 0x04, 0x00])
        
        var searchStart = propBlob.startIndex + 8
        while searchStart < propBlob.endIndex,
              let range = propBlob.range(of: pattern, in: searchStart..<propBlob.endIndex) {
            let baseOffset = range.lowerBound - propBlob.startIndex
            if baseOffset + 10 <= propBlob.count {
                let getSet = propBlob[propBlob.startIndex + baseOffset + 4]
                let isEnabled = propBlob[propBlob.startIndex + baseOffset + 5]
                if (getSet <= 0x01 || getSet >= 0x80) && isEnabled <= 0x02 {
                    if let currentValue = propBlob.readUInt16LE(at: baseOffset + 8) {
                        return currentValue
                    }
                }
            }
            searchStart = range.upperBound
        }
        return nil
    }
}

extension Data {
    nonisolated mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    
    nonisolated func readUInt16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let idx = startIndex + offset
        return UInt16(self[idx]) | (UInt16(self[idx + 1]) << 8)
    }
    
    nonisolated func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let idx = startIndex + offset
        return UInt32(self[idx])
            | (UInt32(self[idx + 1]) << 8)
            | (UInt32(self[idx + 2]) << 16)
            | (UInt32(self[idx + 3]) << 24)
    }
}

