import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import UIKit

enum SegmentationQuality: Sendable {
    /// Uses Vision `.balanced` real-time video segmentation on the Apple Neural Engine
    /// combined with Hermite smoothstep matte solidification and motion-adaptive temporal EMA stabilization.
    case liveFast
    /// Uses a hybrid Vision `VNGenerateForegroundInstanceMaskRequest` + `VNGeneratePersonSegmentationRequest` (`.accurate`)
    /// pipeline with shadow-lifted Vision input and `360x240` hysteresis limb rescue to preserve props/costumes/hair,
    /// eliminate sequin curtain bleed, and recover shadowed limbs/hands.
    case captureAccurate
}

final class BackdropCompositorService: Sendable {
    
    /// Precomputed 256-entry Hermite smoothstep LUT (`3t^2 - 2t^3`) for Live View masks (`48..202` -> `0..255`).
    /// Eliminates background wall bleed-through (`<= 48` -> `0`) and translucent clothing holes (`>= 202` -> `255`).
    nonisolated static let liveMatteLUT: [UInt8] = buildSmoothstepLUT(lowClip: 48, highClip: 202)
    
    /// Precomputed 256-entry Hermite smoothstep LUT for Capture/GIF `.accurate` masks (`32..216` -> `0..255`).
    nonisolated static let accurateMatteLUT: [UInt8] = buildSmoothstepLUT(lowClip: 32, highClip: 216)
    
    nonisolated static func buildSmoothstepLUT(lowClip: Int, highClip: Int) -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256)
        let span = Double(max(1, highClip - lowClip))
        for i in 0..<256 {
            if i <= lowClip {
                lut[i] = 0
            } else if i >= highClip {
                lut[i] = 255
            } else {
                let t = Double(i - lowClip) / span
                let s = t * t * (3.0 - 2.0 * t)
                lut[i] = UInt8(clamping: Int((s * 255.0).rounded()))
            }
        }
        return lut
    }
    
    /// Applies Hermite smoothstep matte solidification and motion-adaptive temporal EMA filtering
    /// to a single-channel 8-bit segmentation mask buffer.
    /// - Stationary/shimmering boundary pixels (`diff < 85`) blend 47% current + 53% previous to eliminate edge jitter.
    /// - Moderate motion pixels (`85 <= diff < 155`) blend 75% current + 25% previous.
    /// - Fast motion pixels (`diff >= 155`) blend 93% current + 7% previous so moving hands/arms never leave ghost trails.
    nonisolated static func solidifyAndTemporalSmoothMask(
        rawRowBytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        srcBytesPerRow: Int,
        lut: [UInt8],
        temporalBuffer: inout [UInt8],
        enableTemporalSmoothing: Bool
    ) {
        let count = width * height
        guard count > 0 else { return }
        let hasValidPrior = enableTemporalSmoothing && (temporalBuffer.count == count)
        if temporalBuffer.count != count {
            temporalBuffer = [UInt8](repeating: 0, count: count)
        }
        
        temporalBuffer.withUnsafeMutableBufferPointer { dstPtr in
            guard let dstBase = dstPtr.baseAddress else { return }
            if hasValidPrior {
                for y in 0..<height {
                    let srcRow = rawRowBytes.advanced(by: y * srcBytesPerRow)
                    let dstRow = dstBase.advanced(by: y * width)
                    for x in 0..<width {
                        let solid = Int(lut[Int(srcRow[x])])
                        let prev = Int(dstRow[x])
                        let diff = abs(solid - prev)
                        let smoothed: Int
                        if diff < 85 {
                            smoothed = (solid * 120 + prev * 136) >> 8
                        } else if diff < 155 {
                            smoothed = (solid * 192 + prev * 64) >> 8
                        } else {
                            smoothed = (solid * 238 + prev * 18) >> 8
                        }
                        dstRow[x] = UInt8(clamping: smoothed)
                    }
                }
            } else {
                for y in 0..<height {
                    let srcRow = rawRowBytes.advanced(by: y * srcBytesPerRow)
                    let dstRow = dstBase.advanced(by: y * width)
                    for x in 0..<width {
                        dstRow[x] = lut[Int(srcRow[x])]
                    }
                }
            }
        }
    }
    
    private nonisolated final class AssetImageCache: @unchecked Sendable {
        static let shared = AssetImageCache()
        private let lock = NSLock()
        private var cache: [String: CIImage] = [:]
        
        private let liveSegmentationLock = NSLock()
        private var reusableBalancedRequest: VNGeneratePersonSegmentationRequest?
        private var temporalMaskBuffer: [UInt8] = []
        private var temporalWidth: Int = 0
        private var temporalHeight: Int = 0
        private var lastLiveMaskTimestampNs: UInt64 = 0
        
        private let accurateSegmentationLock = NSLock()
        private var reusableAccurateRequest: VNGeneratePersonSegmentationRequest?
        
        func image(forKey key: String, loader: () -> CIImage?) -> CIImage? {
            lock.lock()
            if let existing = cache[key] {
                lock.unlock()
                return existing
            }
            lock.unlock()
            
            guard let loaded = loader() else { return nil }
            lock.lock()
            if cache.count >= 8 {
                cache.removeAll()
            }
            cache[key] = loaded
            lock.unlock()
            return loaded
        }
        
        func clear() {
            lock.lock()
            cache.removeAll()
            lock.unlock()
            resetTemporalState()
        }
        
        func resetTemporalState() {
            liveSegmentationLock.lock()
            temporalMaskBuffer.removeAll(keepingCapacity: true)
            temporalWidth = 0
            temporalHeight = 0
            lastLiveMaskTimestampNs = 0
            liveSegmentationLock.unlock()
        }
        
        func performLiveBalancedSegmentation(on ciImage: CIImage) -> CIImage? {
            liveSegmentationLock.lock()
            defer { liveSegmentationLock.unlock() }
            
            let request: VNGeneratePersonSegmentationRequest
            if let existing = reusableBalancedRequest {
                request = existing
            } else {
                let req = VNGeneratePersonSegmentationRequest()
                // `.balanced` is Apple's real-time video segmentation neural network (dramatically cleaner
                // boundaries and interior confidence than `.fast`, while running at live frame rates on ANE).
                req.qualityLevel = .balanced
                req.outputPixelFormat = kCVPixelFormatType_OneComponent8
                reusableBalancedRequest = req
                request = req
            }
            
            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
                guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
                
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let isContinuousStream = (lastLiveMaskTimestampNs > 0) && ((nowNs - lastLiveMaskTimestampNs) <= 450_000_000)
                lastLiveMaskTimestampNs = nowNs
                
                return Self.createSolidifiedMaskCIImage(
                    from: pixelBuffer,
                    lut: BackdropCompositorService.liveMatteLUT,
                    temporalBuffer: &temporalMaskBuffer,
                    previousWidth: &temporalWidth,
                    previousHeight: &temporalHeight,
                    enableTemporalSmoothing: isContinuousStream
                )
            } catch {
                return nil
            }
        }
        
        func performAccurateSegmentation(
            on ciImage: CIImage,
            ciContext: CIContext
        ) -> (mask: CIImage, isFullResolutionHybrid: Bool)? {
            accurateSegmentationLock.lock()
            defer { accurateSegmentationLock.unlock() }
            
            let rawExtent = ciImage.extent
            let w = rawExtent.width
            let h = rawExtent.height
            guard w > 1, h > 1 else { return nil }
            let extent = CGRect(x: 0, y: 0, width: w, height: h)
            let normalizedCI = (rawExtent.minX != 0 || rawExtent.minY != 0)
                ? ciImage.transformed(by: CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY))
                : ciImage
            
            // 1. Sample 360x240 RGB grid for scene luminance and hysteresis limb rescue
            let gw = 360, gh = 240
            let gExtent = CGRect(x: 0, y: 0, width: gw, height: gh)
            let sx = CGFloat(gw) / w
            let sy = CGFloat(gh) / h
            let smallRGB = normalizedCI
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: gExtent)
            var rgbBytes = [UInt8](repeating: 0, count: gw * gh * 4)
            ciContext.render(
                smallRGB,
                toBitmap: &rgbBytes,
                rowBytes: gw * 4,
                bounds: gExtent,
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            
            var lumaSum = 0
            let cellCount = gw * gh
            for i in 0..<cellCount {
                lumaSum += (Int(rgbBytes[i * 4]) * 2 + Int(rgbBytes[i * 4 + 1]) * 5 + Int(rgbBytes[i * 4 + 2])) >> 3
            }
            let meanLuma = Double(lumaSum) / Double(cellCount)
            
            // 2. Build a shadow-lifted input image ONLY for the Vision neural network pass so dark hair,
            //    black sleeves, and shadowed limbs cleanly separate from dark studio curtains without
            //    altering the actual subject pixels.
            let shadowAmt = meanLuma < 65.0 ? 0.62 : 0.45
            let evAmt = meanLuma < 65.0 ? 0.52 : 0.35
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = normalizedCI
            hs.shadowAmount = Float(shadowAmt)
            hs.highlightAmount = 0.93
            let ev = CIFilter.exposureAdjust()
            ev.inputImage = hs.outputImage ?? normalizedCI
            ev.ev = Float(evAmt)
            let visionCI = (ev.outputImage ?? normalizedCI).cropped(to: extent)
            
            let personSeg: VNGeneratePersonSegmentationRequest
            if let existing = reusableAccurateRequest {
                personSeg = existing
            } else {
                let req = VNGeneratePersonSegmentationRequest()
                req.qualityLevel = .accurate
                req.outputPixelFormat = kCVPixelFormatType_OneComponent8
                reusableAccurateRequest = req
                personSeg = req
            }
            let fgInst = VNGenerateForegroundInstanceMaskRequest()
            
            let handler = VNImageRequestHandler(ciImage: visionCI, options: [:])
            do {
                try handler.perform([fgInst, personSeg])
            } catch {
                // Fallback if running both requests together fails on an unsupported environment
                do {
                    try handler.perform([personSeg])
                } catch {
                    return nil
                }
            }
            
            // 3. Hybrid Foreground Instance + Person Segmentation Limb-Rescue Path
            if let obs = fgInst.results?.first,
               !obs.allInstances.isEmpty,
               let fgPB = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler),
               let personPB = personSeg.results?.first?.pixelBuffer {
                
                let fgRawCI = CIImage(cvPixelBuffer: fgPB)
                guard fgRawCI.extent.width > 0, fgRawCI.extent.height > 0 else { return nil }
                let fgMaskCI = fgRawCI
                    .transformed(by: CGAffineTransform(translationX: -fgRawCI.extent.minX, y: -fgRawCI.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: w / fgRawCI.extent.width, y: h / fgRawCI.extent.height))
                    .cropped(to: extent)
                
                let pRawCI = CIImage(cvPixelBuffer: personPB)
                guard pRawCI.extent.width > 0, pRawCI.extent.height > 0 else { return nil }
                let pMaskCI = pRawCI
                    .transformed(by: CGAffineTransform(translationX: -pRawCI.extent.minX, y: -pRawCI.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: w / pRawCI.extent.width, y: h / pRawCI.extent.height))
                    .cropped(to: extent)
                
                let smallFg = fgMaskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: gExtent)
                let smallP = pMaskCI.transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: gExtent)
                
                var fgBytes = [UInt8](repeating: 0, count: cellCount)
                var pBytes = [UInt8](repeating: 0, count: cellCount)
                ciContext.render(smallFg, toBitmap: &fgBytes, rowBytes: gw, bounds: gExtent, format: .R8, colorSpace: nil)
                ciContext.render(smallP, toBitmap: &pBytes, rowBytes: gw, bounds: gExtent, format: .R8, colorSpace: nil)
                
                func isNearFg(_ x: Int, _ y: Int, rad: Int) -> Bool {
                    let minY = max(0, y - rad), maxY = min(gh - 1, y + rad)
                    let minX = max(0, x - rad), maxX = min(gw - 1, x + rad)
                    for ny in minY...maxY {
                        let row = ny * gw
                        for nx in minX...maxX {
                            if fgBytes[row + nx] >= 128 { return true }
                        }
                    }
                    return false
                }
                
                func isValidSeedColor(_ r: Int, _ g: Int, _ b: Int) -> Bool {
                    return r >= 75 && (r - b) >= 15 && g >= 40
                }
                
                // Identify disconnected missed-limb seeds where personSeg is confident (>= 200),
                // fgInst missed (< 32 and not within 5 cells of fgInst), and color is warm skin/prop
                var seedQueue: [Int] = []
                for y in 0..<gh {
                    for x in 0..<gw {
                        let i = y * gw + x
                        if fgBytes[i] < 32 && pBytes[i] >= 200 && !isNearFg(x, y, rad: 5) {
                            let r = Int(rgbBytes[i * 4]), g = Int(rgbBytes[i * 4 + 1]), b = Int(rgbBytes[i * 4 + 2])
                            if isValidSeedColor(r, g, b) {
                                seedQueue.append(i)
                            }
                        }
                    }
                }
                
                var rescueRGBA = [UInt8](repeating: 0, count: cellCount * 4)
                var rescuedCount = 0
                let dirs = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
                
                if seedQueue.count >= 65 {
                    var visitedSeed = [Bool](repeating: false, count: cellCount)
                    for startIdx in seedQueue {
                        if visitedSeed[startIdx] { continue }
                        var clusterSeeds: [Int] = [startIdx]
                        visitedSeed[startIdx] = true
                        var farSeedCount = 0
                        var head = 0
                        while head < clusterSeeds.count {
                            let c = clusterSeeds[head]; head += 1
                            let cx = c % gw, cy = c / gw
                            if !isNearFg(cx, cy, rad: 7) { farSeedCount += 1 }
                            for dy in -4...4 {
                                for dx in -4...4 {
                                    let nx = cx + dx, ny = cy + dy
                                    if nx >= 0 && nx < gw && ny >= 0 && ny < gh {
                                        let ni = ny * gw + nx
                                        if !visitedSeed[ni] && fgBytes[ni] < 32 && pBytes[ni] >= 200 && !isNearFg(nx, ny, rad: 5) {
                                            let r = Int(rgbBytes[ni * 4]), g = Int(rgbBytes[ni * 4 + 1]), b = Int(rgbBytes[ni * 4 + 2])
                                            if isValidSeedColor(r, g, b) {
                                                visitedSeed[ni] = true
                                                clusterSeeds.append(ni)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if clusterSeeds.count < 65 || farSeedCount < 25 { continue }
                        
                        var minX = gw, maxX = 0, minY = gh, maxY = 0
                        for idx in clusterSeeds {
                            let x = idx % gw, y = idx / gw
                            if x < minX { minX = x }; if x > maxX { maxX = x }
                            if y < minY { minY = y }; if y > maxY { maxY = y }
                        }
                        let allowMinX = max(0, minX - gw / 5), allowMaxX = min(gw - 1, maxX + gw / 5)
                        let allowMinY = max(0, minY - gh / 5), allowMaxY = min(gh - 1, maxY + gh / 5)
                        
                        var q = clusterSeeds
                        var visitedGrow = [Bool](repeating: false, count: cellCount)
                        for idx in q {
                            visitedGrow[idx] = true
                            rescueRGBA[idx * 4] = 255
                            rescueRGBA[idx * 4 + 1] = 255
                            rescueRGBA[idx * 4 + 2] = 255
                            rescueRGBA[idx * 4 + 3] = 255
                        }
                        var gHead = 0
                        while gHead < q.count {
                            let curr = q[gHead]; gHead += 1
                            let cx = curr % gw, cy = curr / gw
                            for (dx, dy) in dirs {
                                let nx = cx + dx, ny = cy + dy
                                if nx >= allowMinX && nx <= allowMaxX && ny >= allowMinY && ny <= allowMaxY {
                                    let ni = ny * gw + nx
                                    let r = Int(rgbBytes[ni * 4]), b = Int(rgbBytes[ni * 4 + 2])
                                    let pVal = pBytes[ni]
                                    if !visitedGrow[ni] && pVal >= 120 && (b - r) < 8 {
                                        visitedGrow[ni] = true
                                        rescueRGBA[ni * 4] = 255
                                        rescueRGBA[ni * 4 + 1] = 255
                                        rescueRGBA[ni * 4 + 2] = 255
                                        rescueRGBA[ni * 4 + 3] = 255
                                        q.append(ni)
                                    }
                                }
                            }
                        }
                        rescuedCount += q.count
                    }
                }
                
                // Normalize fgMaskCI to R=G=B=r, A=1 clamped to [0, 1]
                let normFg = fgMaskCI.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ]).applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                ]).cropped(to: extent)
                
                if rescuedCount > 0 {
                    var dilatedRGBA = rescueRGBA
                    for y in 1..<(gh - 1) {
                        for x in 1..<(gw - 1) {
                            let i = y * gw + x
                            if rescueRGBA[i * 4] == 255 {
                                for dy in -1...1 {
                                    for dx in -1...1 {
                                        let ni = (y + dy) * gw + (x + dx)
                                        let r = Int(rgbBytes[ni * 4]), b = Int(rgbBytes[ni * 4 + 2])
                                        if (b - r) < 8 {
                                            dilatedRGBA[ni * 4] = 255
                                            dilatedRGBA[ni * 4 + 1] = 255
                                            dilatedRGBA[ni * 4 + 2] = 255
                                            dilatedRGBA[ni * 4 + 3] = 255
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let rescueData = Data(dilatedRGBA)
                    let rescueSmallCI = CIImage(
                        bitmapData: rescueData,
                        bytesPerRow: gw * 4,
                        size: CGSize(width: gw, height: gh),
                        format: .RGBA8,
                        colorSpace: nil
                    )
                    let rescueScaled = rescueSmallCI
                        .clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5])
                        .cropped(to: gExtent)
                        .transformed(by: CGAffineTransform(scaleX: w / CGFloat(gw), y: h / CGFloat(gh)))
                        .cropped(to: extent)
                    
                    let boostedPerson = pMaskCI.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 4.5, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 4.5, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 4.5, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBiasVector": CIVector(x: -1.0, y: -1.0, z: -1.0, w: 1.0)
                    ]).applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
                    ]).cropped(to: extent)
                    
                    let gateFilter = CIFilter.blendWithRedMask()
                    gateFilter.inputImage = boostedPerson
                    gateFilter.backgroundImage = CIImage(color: .black).cropped(to: extent)
                    gateFilter.maskImage = rescueScaled
                    if let gatedPerson = gateFilter.outputImage?.cropped(to: extent),
                       let maxF = CIFilter(name: "CIMaximumCompositing") {
                        maxF.setValue(normFg, forKey: kCIInputImageKey)
                        maxF.setValue(gatedPerson, forKey: kCIInputBackgroundImageKey)
                        if let fused = maxF.outputImage?.cropped(to: extent) {
                            return (fused, true)
                        }
                    }
                }
                
                return (normFg, true)
            }
            
            // 4. Fallback to solidified person segmentation if fgInst produced no instances (e.g. flat synthetic test images)
            guard let pixelBuffer = personSeg.results?.first?.pixelBuffer else { return nil }
            var scratchBuffer: [UInt8] = []
            var pw = 0
            var ph = 0
            guard let fallbackMask = Self.createSolidifiedMaskCIImage(
                from: pixelBuffer,
                lut: BackdropCompositorService.accurateMatteLUT,
                temporalBuffer: &scratchBuffer,
                previousWidth: &pw,
                previousHeight: &ph,
                enableTemporalSmoothing: false
            ) else {
                return nil
            }
            return (fallbackMask, false)
        }
        
        private static func createSolidifiedMaskCIImage(
            from pixelBuffer: CVPixelBuffer,
            lut: [UInt8],
            temporalBuffer: inout [UInt8],
            previousWidth: inout Int,
            previousHeight: inout Int,
            enableTemporalSmoothing: Bool
        ) -> CIImage? {
            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                return CIImage(cvPixelBuffer: pixelBuffer)
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard width > 0, height > 0,
                  let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return CIImage(cvPixelBuffer: pixelBuffer)
            }
            
            let dimensionsMatch = (width == previousWidth && height == previousHeight)
            previousWidth = width
            previousHeight = height
            
            BackdropCompositorService.solidifyAndTemporalSmoothMask(
                rawRowBytes: baseAddr,
                width: width,
                height: height,
                srcBytesPerRow: bytesPerRow,
                lut: lut,
                temporalBuffer: &temporalBuffer,
                enableTemporalSmoothing: enableTemporalSmoothing && dimensionsMatch
            )
            
            let graySpace = CGColorSpaceCreateDeviceGray()
            let maskData = Data(temporalBuffer)
            guard let provider = CGDataProvider(data: maskData as CFData),
                  let cgImage = CGImage(
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bitsPerPixel: 8,
                      bytesPerRow: width,
                      space: graySpace,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: true,
                      intent: .defaultIntent
                  ) else {
                return CIImage(cvPixelBuffer: pixelBuffer)
            }
            return CIImage(cgImage: cgImage)
        }
    }
    
    nonisolated static func clearCache() {
        AssetImageCache.shared.clear()
    }
    
    nonisolated static func resetLiveTemporalState() {
        AssetImageCache.shared.resetTemporalState()
    }
    
    // MARK: - 3-Layer Compositing (Background -> Segmented Subject -> Foreground Frame)
    
    /// Composites `backdrop` onto `cgImage` using the 3-layer stack:
    /// 1. Background image (auto-scaled via Aspect-Fill + Center Crop)
    /// 2. Subject image (segmented via Vision when a Background is present; untouched when Foreground-only)
    /// 3. Foreground transparent PNG frame (scaled via `backdrop.foregroundFitMode`, defaulting to Stretch-to-Edges)
    nonisolated static func composite(
        cgImage: CGImage,
        backdrop: BackdropItem,
        quality: SegmentationQuality,
        ciContext: CIContext,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = [],
        customMaskProvider: ((CIImage) -> CIImage?)? = nil
    ) -> CGImage {
        guard !backdrop.isNone else { return cgImage }
        let subjectCI = CIImage(cgImage: cgImage)
        return composite(
            subjectCI: subjectCI,
            backdrop: backdrop,
            quality: quality,
            ciContext: ciContext,
            customBackgroundData: customBackgroundData,
            customForegroundData: customForegroundData,
            additionalSearchDirectories: additionalSearchDirectories,
            customMaskProvider: customMaskProvider
        ) ?? cgImage
    }
    
    /// Single-pass `CIImage` compositor used by both `composite(cgImage:...)` and 30 FPS `LocalCameraClient` Live View
    /// (avoiding an intermediate `createCGImage` pass before segmentation).
    nonisolated static func composite(
        subjectCI: CIImage,
        backdrop: BackdropItem,
        quality: SegmentationQuality,
        ciContext: CIContext,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = [],
        customMaskProvider: ((CIImage) -> CIImage?)? = nil
    ) -> CGImage? {
        let rawExtent = subjectCI.extent
        let targetWidth = rawExtent.width
        let targetHeight = rawExtent.height
        guard targetWidth > 1, targetHeight > 1 else { return nil }
        
        let normalizedSubject: CIImage
        if rawExtent.minX != 0 || rawExtent.minY != 0 {
            normalizedSubject = subjectCI.transformed(by: CGAffineTransform(translationX: -rawExtent.minX, y: -rawExtent.minY))
        } else {
            normalizedSubject = subjectCI
        }
        let targetExtent = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        
        guard !backdrop.isNone else {
            return ciContext.createCGImage(normalizedSubject, from: targetExtent)
        }
        
        // Load optional Background CIImage
        let bgCI: CIImage? = loadLayerCIImage(
            filename: backdrop.backgroundFilename,
            customData: customBackgroundData,
            cachePrefix: "bg_\(backdrop.id)",
            additionalSearchDirectories: additionalSearchDirectories
        )
        
        // Load optional Foreground CIImage
        let fgCI: CIImage? = loadLayerCIImage(
            filename: backdrop.foregroundFilename,
            customData: customForegroundData,
            cachePrefix: "fg_\(backdrop.id)",
            additionalSearchDirectories: additionalSearchDirectories
        )
        
        guard bgCI != nil || fgCI != nil else {
            return ciContext.createCGImage(normalizedSubject, from: targetExtent)
        }
        
        // Layer 1 + Layer 2: Background Replacement (only runs Vision segmentation if a background image is active)
        var compositedCI: CIImage = normalizedSubject
        if let rawBg = bgCI {
            let scaledBg = scaleImage(rawBg, to: targetExtent, mode: .aspectFill)
            if let maskCI = generatePersonMask(
                for: normalizedSubject,
                targetExtent: targetExtent,
                quality: quality,
                ciContext: ciContext,
                customMaskProvider: customMaskProvider
            ) {
                if let blendFilter = CIFilter(name: "CIBlendWithMask") {
                    blendFilter.setValue(normalizedSubject, forKey: kCIInputImageKey)
                    blendFilter.setValue(scaledBg, forKey: kCIInputBackgroundImageKey)
                    blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
                    if let blended = blendFilter.outputImage?.cropped(to: targetExtent) {
                        compositedCI = blended
                    }
                }
            }
        }
        
        // Layer 3: Foreground Frame Overlay (alpha-composited in front of subject & background)
        if let rawFg = fgCI {
            let scaledFg = scaleImage(rawFg, to: targetExtent, mode: backdrop.foregroundFitMode)
            compositedCI = scaledFg.composited(over: compositedCI).cropped(to: targetExtent)
        }
        
        return ciContext.createCGImage(compositedCI, from: targetExtent)
    }
    
    // MARK: - Vision Person Segmentation + Edge Feathering
    
    nonisolated private static func generatePersonMask(
        for subjectCI: CIImage,
        targetExtent: CGRect,
        quality: SegmentationQuality,
        ciContext: CIContext,
        customMaskProvider: ((CIImage) -> CIImage?)?
    ) -> CIImage? {
        if let provider = customMaskProvider, let customMask = provider(subjectCI) {
            return scaleImage(customMask, to: targetExtent, mode: .stretchToEdges)
        }
        
        let rawMaskCI: CIImage?
        switch quality {
        case .liveFast:
            rawMaskCI = AssetImageCache.shared.performLiveBalancedSegmentation(on: subjectCI)
        case .captureAccurate:
            guard let accurateResult = AssetImageCache.shared.performAccurateSegmentation(
                on: subjectCI,
                ciContext: ciContext
            ) else {
                return nil
            }
            if accurateResult.isFullResolutionHybrid {
                return accurateResult.mask.cropped(to: targetExtent)
            }
            rawMaskCI = accurateResult.mask
        }
        
        guard let rawMaskCI = rawMaskCI else { return nil }
        let maskExtent = rawMaskCI.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return nil }
        
        let scaleX = targetExtent.width / maskExtent.width
        let scaleY = targetExtent.height / maskExtent.height
        var scaledMask = rawMaskCI
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: targetExtent)
        
        // Apply proportional soft edge feathering so hair & shoulder boundaries blend naturally without stair-stepping
        let blurRadius = max(1.0, min(3.5, targetExtent.width * 0.0010))
        scaledMask = scaledMask
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: targetExtent)
        
        return scaledMask
    }
    
    // MARK: - Resolution Auto-Scaling Helper
    
    nonisolated static func scaleImage(
        _ image: CIImage,
        to targetExtent: CGRect,
        mode: ForegroundFitMode
    ) -> CIImage {
        let srcExtent = image.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return image }
        
        // Normalize origin to (0, 0) first
        let normalized = image.transformed(by: CGAffineTransform(translationX: -srcExtent.minX, y: -srcExtent.minY))
        
        switch mode {
        case .stretchToEdges:
            let sx = targetExtent.width / srcExtent.width
            let sy = targetExtent.height / srcExtent.height
            return normalized
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY))
                .cropped(to: targetExtent)
            
        case .aspectFill:
            let scale = max(targetExtent.width / srcExtent.width, targetExtent.height / srcExtent.height)
            let scaledW = srcExtent.width * scale
            let scaledH = srcExtent.height * scale
            let offsetX = targetExtent.minX + (targetExtent.width - scaledW) * 0.5
            let offsetY = targetExtent.minY + (targetExtent.height - scaledH) * 0.5
            return normalized
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: targetExtent)
            
        case .aspectFit:
            let scale = min(targetExtent.width / srcExtent.width, targetExtent.height / srcExtent.height)
            let scaledW = srcExtent.width * scale
            let scaledH = srcExtent.height * scale
            let offsetX = targetExtent.minX + (targetExtent.width - scaledW) * 0.5
            let offsetY = targetExtent.minY + (targetExtent.height - scaledH) * 0.5
            return normalized
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: targetExtent)
        }
    }
    
    nonisolated private static func decodeBitmapBackedCIImage(from source: CGImageSource) -> CIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return CIImage(cgImage: cg)
        }
        return nil
    }
    
    /// Returns `true` only if all declared layers (`backgroundFilename` and/or `foregroundFilename`)
    /// of `backdrop` can be resolved either via embedded `Data` or on disk.
    nonisolated static func hasResolvableAssets(
        for backdrop: BackdropItem,
        customBackgroundData: Data? = nil,
        customForegroundData: Data? = nil,
        additionalSearchDirectories: [URL] = []
    ) -> Bool {
        if backdrop.isNone { return false }
        var hasAnyLayer = false
        if let bgName = backdrop.backgroundFilename, !bgName.isEmpty {
            hasAnyLayer = true
            let hasBgData = (customBackgroundData != nil && !(customBackgroundData?.isEmpty ?? true))
            let hasBgFile = BackdropManager.resolveAssetURL(filename: bgName, additionalSearchDirectories: additionalSearchDirectories) != nil
            if !hasBgData && !hasBgFile {
                return false
            }
        }
        if let fgName = backdrop.foregroundFilename, !fgName.isEmpty {
            hasAnyLayer = true
            let hasFgData = (customForegroundData != nil && !(customForegroundData?.isEmpty ?? true))
            let hasFgFile = BackdropManager.resolveAssetURL(filename: fgName, additionalSearchDirectories: additionalSearchDirectories) != nil
            if !hasFgData && !hasFgFile {
                return false
            }
        }
        return hasAnyLayer
    }
    
    nonisolated private static func loadLayerCIImage(
        filename: String?,
        customData: Data?,
        cachePrefix: String,
        additionalSearchDirectories: [URL]
    ) -> CIImage? {
        if let data = customData, !data.isEmpty {
            let key = "\(cachePrefix)_data_\(data.count)_\(data.hashValue)"
            return AssetImageCache.shared.image(forKey: key) {
                if let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let decoded = decodeBitmapBackedCIImage(from: src) {
                    return decoded
                }
                return CIImage(data: data, options: [.applyOrientationProperty: true])
            }
        }
        guard let filename = filename, !filename.isEmpty else { return nil }
        let dirScope = additionalSearchDirectories.first?.path ?? ""
        let key = dirScope.isEmpty
            ? "\(cachePrefix)_file_\(filename)"
            : "\(cachePrefix)_dir_\(dirScope)_file_\(filename)"
        return AssetImageCache.shared.image(forKey: key) {
            guard let url = BackdropManager.resolveAssetURL(
                filename: filename,
                additionalSearchDirectories: additionalSearchDirectories
            ) else { return nil }
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let decoded = decodeBitmapBackedCIImage(from: src) {
                return decoded
            }
            return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
    }
    
    // MARK: - 3:2 Landscape Aspect Ratio Enforcement & Front-Camera Selfie Pre-Mirroring
    
    /// Target aspect ratio (`3:2 = 1.500:1`) for all photobooth Live View frames, captured Photos, GIFs, and backdrops.
    nonisolated static let targetPhotoboothAspectRatio: CGFloat = 3.0 / 2.0
    
    /// Center-crops any `CIImage` to landscape `3:2` (`width : height = 3 : 2 = 1.500:1`) and normalizes its origin to `(0, 0)`.
    /// - For `4:3` (`1.333:1`) iPad camera frames (e.g. `1440x1080` Live View or `4032x3024` photo), preserves 100% of the width
    ///   and trims top/bottom equally to `1440x960` / `4032x2688` (`3:2`).
    /// - For `16:9` (`1.778:1`) frames (e.g. `1920x1080`), preserves 100% of the height and trims left/right equally to `1620x1080` (`3:2`).
    /// - For frames already at `3:2` (e.g. `3504x2336`, `1620x1080`, `1024x680`), preserves dimensions untouched.
    nonisolated static func cropToLandscapeThreeByTwo(_ ciImage: CIImage) -> CIImage {
        let ext = ciImage.extent
        guard ext.width > 1, ext.height > 1 else { return ciImage }
        let normalized = (ext.minX != 0 || ext.minY != 0)
            ? ciImage.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            : ciImage
        let w = normalized.extent.width
        let h = normalized.extent.height
        let currentAspect = w / h
        let targetAspect = targetPhotoboothAspectRatio
        
        if abs(currentAspect - targetAspect) <= 0.008 {
            return normalized
        }
        
        let cropW: CGFloat
        let cropH: CGFloat
        if currentAspect < targetAspect {
            // Narrower/taller than 3:2 (e.g. 4:3 = 1.3333): keep 100% of width, center-crop height to width * 2/3
            cropW = w
            cropH = max(1.0, (w / targetAspect).rounded())
        } else {
            // Wider than 3:2 (e.g. 16:9 = 1.7778): keep 100% of height, center-crop width to height * 3/2
            cropW = max(1.0, (h * targetAspect).rounded())
            cropH = h
        }
        
        let offsetX = ((w - cropW) * 0.5).rounded(.down)
        let offsetY = ((h - cropH) * 0.5).rounded(.down)
        let cropRect = CGRect(x: offsetX, y: offsetY, width: cropW, height: cropH)
        return normalized
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
    }
    
    /// Center-crops any `CGImage` to landscape `3:2` (`width : height = 3 : 2 = 1.500:1`).
    nonisolated static func cropToLandscapeThreeByTwo(_ cgImage: CGImage) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        guard w > 1, h > 1 else { return cgImage }
        let currentAspect = w / h
        let targetAspect = targetPhotoboothAspectRatio
        
        if abs(currentAspect - targetAspect) <= 0.008 {
            return cgImage
        }
        
        let cropW: CGFloat
        let cropH: CGFloat
        if currentAspect < targetAspect {
            cropW = w
            cropH = max(1.0, (w / targetAspect).rounded())
        } else {
            cropW = max(1.0, (h * targetAspect).rounded())
            cropH = h
        }
        
        let offsetX = ((w - cropW) * 0.5).rounded(.down)
        let offsetY = ((h - cropH) * 0.5).rounded(.down)
        let cropRect = CGRect(x: offsetX, y: offsetY, width: cropW, height: cropH)
        return cgImage.cropping(to: cropRect) ?? cgImage
    }
    
    /// Orients, horizontally mirrors, and center-crops a raw front-camera `CIImage` into upright landscape `3:2`
    /// display coordinates BEFORE any backdrop or foreground frame is composited, so the guest sees a natural mirror
    /// at the exact `3:2` photobooth aspect ratio while foreground text (e.g. "Evan's Bar Mitzvah") stays 100% right-side up and un-reversed.
    nonisolated static func orientAndMirrorFrontCameraCIImage(
        _ rawCIImage: CIImage,
        interfaceOrientation: UIDeviceOrientation
    ) -> CIImage {
        // Step 1: Rotate raw front-camera sensor buffer to upright LANDSCAPE display coordinates.
        // All photobooth backgrounds and foreground frames are landscape 3:2 (3504x2336), so we never
        // rotate a landscape sensor buffer 90° into vertical 3:4 portrait (which would scale the image
        // down left-to-right and add black bars on the left and right of the iPad screen).
        let isRawSensorLandscape = rawCIImage.extent.width >= rawCIImage.extent.height
        let uprightExif: CGImagePropertyOrientation
        if ProcessInfo.processInfo.isiOSAppOnMac {
            uprightExif = isRawSensorLandscape ? .up : .right
        } else {
            switch interfaceOrientation {
            case .landscapeLeft:
                // UIDeviceOrientation.landscapeLeft == UIInterfaceOrientation.landscapeRight (home/USB-C on right)
                uprightExif = isRawSensorLandscape ? .down : .right
            case .landscapeRight:
                // UIDeviceOrientation.landscapeRight == UIInterfaceOrientation.landscapeLeft (home/USB-C on left)
                uprightExif = isRawSensorLandscape ? .up : .left
            default:
                // Keep landscape orientation when stationary in a stand, tilted, or at launch
                uprightExif = isRawSensorLandscape ? .down : .right
            }
        }
        let upright = rawCIImage.oriented(forExifOrientation: Int32(uprightExif.rawValue))
        let ext = upright.extent
        let normalizedUpright = upright.transformed(
            by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY)
        )
        
        // Step 2: Horizontally mirror the upright subject image so selfie motion feels like a natural mirror,
        // while any subsequently composited foreground text/frame remains un-mirrored.
        let mirrored = normalizedUpright
            .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
            .transformed(by: CGAffineTransform(translationX: ext.width, y: 0))
        
        // Step 3: Center-crop the 4:3 (or 16:9) front-camera buffer to exact 3:2 landscape aspect ratio
        // so Live View, captured Photos, and GIFs match the 3:2 backgrounds/foregrounds and span 100% width
        // on the iPad with top/bottom black bars only.
        return cropToLandscapeThreeByTwo(mirrored)
    }
    
    /// Horizontally mirrors an already-upright `CGImage` (used in deterministic QA tests for front-camera selfie pre-mirroring).
    nonisolated static func mirrorCGImageHorizontally(_ cgImage: CGImage, ciContext: CIContext) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let ci = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
            .transformed(by: CGAffineTransform(translationX: w, y: 0))
        return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) ?? cgImage
    }
    
    // MARK: - Triple-Lock Metadata & 8x8 Perceptual RGB Signature
    
    /// Parses the camera filename (e.g. `"DSC04821.JPG"`) from an ISO 15740 PTP `ObjectInfo` (`0x1008`) response payload.
    nonisolated static func parsePTPObjectInfoFilename(from data: Data?) -> String? {
        guard let data = data, data.count >= 16 else { return nil }
        
        func tryParseUTF16Filename(at offset: Int) -> String? {
            guard offset >= 0, offset + 1 < data.count else { return nil }
            let charCount = Int(data[data.startIndex + offset])
            guard charCount >= 5, charCount <= 64, offset + 1 + (charCount * 2) <= data.count else { return nil }
            var scalars: [UInt16] = []
            scalars.reserveCapacity(charCount)
            for i in 0..<charCount {
                let lo = UInt16(data[data.startIndex + offset + 1 + (i * 2)])
                let hi = UInt16(data[data.startIndex + offset + 1 + (i * 2) + 1])
                let codeUnit = lo | (hi << 8)
                if codeUnit == 0 { break }
                // Must be printable ASCII filename characters
                guard codeUnit >= 0x20 && codeUnit <= 0x7E else { return nil }
                scalars.append(codeUnit)
            }
            guard scalars.count >= 5 else { return nil }
            let str = String(utf16CodeUnits: scalars, count: scalars.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = str.uppercased()
            if (upper.hasSuffix(".JPG") || upper.hasSuffix(".JPEG") || upper.hasSuffix(".ARW") || upper.hasSuffix(".HEIF")),
               !upper.contains("/") && !upper.contains("\\") {
                return str
            }
            return nil
        }
        
        // Check standard ISO 15740 offsets first: 52 (raw ObjectInfo dataset) and 64 (12-byte PTP container + 52-byte ObjectInfo)
        for offset in [52, 64] {
            if let found = tryParseUTF16Filename(at: offset) {
                return found
            }
        }
        // Fallback scan in case camera firmware uses a vendor-specific header offset
        let maxScan = min(data.count - 10, 160)
        if maxScan > 0 {
            for offset in 0..<maxScan where offset != 52 && offset != 64 {
                if let found = tryParseUTF16Filename(at: offset) {
                    return found
                }
            }
        }
        return nil
    }
    
    /// Extracts the camera's EXIF `DateTimeOriginal` (or TIFF `DateTime`) and `SubSecTimeOriginal` from image data
    /// without decoding the full pixel buffer (`< 0.1ms` header-only read).
    nonisolated static func extractEXIFTimestamps(from imageData: Data) -> (dateTimeOriginal: String?, subSecOriginal: String?) {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return extractEXIFTimestamps(fromProperties: props)
    }
    
    nonisolated static func extractEXIFTimestamps(from fileURL: URL) -> (dateTimeOriginal: String?, subSecOriginal: String?, backdropAppliedID: String?) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil)
        }
        let (dt, sub) = extractEXIFTimestamps(fromProperties: props)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let userComment = exif?[kCGImagePropertyExifUserComment] as? String
        var appliedID: String? = nil
        if let comment = userComment, comment.hasPrefix("PB2_BACKDROP:") {
            appliedID = String(comment.dropFirst("PB2_BACKDROP:".count))
        }
        return (dt, sub, appliedID)
    }
    
    nonisolated private static func extractEXIFTimestamps(fromProperties props: [CFString: Any]) -> (dateTimeOriginal: String?, subSecOriginal: String?) {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dt = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let subSec = (exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifSubsecTime] as? String)
        return (dt, subSec)
    }
    
    private nonisolated static let exifDateLock = NSLock()
    private nonisolated(unsafe) static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
    
    /// Parses an EXIF date string (`"YYYY:MM:DD HH:MM:SS"`) into a `Date` for $\pm 2\text{s}$ timestamp window matching.
    nonisolated static func parseEXIFDate(_ exifString: String?, subSec: String? = nil) -> Date? {
        guard let exifString = exifString, !exifString.isEmpty else { return nil }
        exifDateLock.lock()
        let baseDate = exifDateFormatter.date(from: exifString)
        exifDateLock.unlock()
        guard let baseDate = baseDate else { return nil }
        if let sub = subSec, let frac = Double("0.\(sub.trimmingCharacters(in: .whitespaces))") {
            return baseDate.addingTimeInterval(frac)
        }
        return baseDate
    }
    
    /// Computes a compact 192-byte (`8x8x3` RGB) perceptual color signature from the center 80% of `cgImage`.
    nonisolated static func computeRGBSignature8x8(from cgImage: CGImage) -> [UInt8] {
        let gridSize = 8
        let totalBytes = gridSize * gridSize * 4
        var rgba = [UInt8](repeating: 0, count: totalBytes)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        
        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: srcW * 0.10,
            y: srcH * 0.10,
            width: max(1, srcW * 0.80),
            height: max(1, srcH * 0.80)
        )
        let croppedCG = cgImage.cropping(to: cropRect) ?? cgImage
        
        rgba.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: gridSize,
                      height: gridSize,
                      bitsPerComponent: 8,
                      bytesPerRow: gridSize * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(croppedCG, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
        }
        
        var rgb = [UInt8]()
        rgb.reserveCapacity(gridSize * gridSize * 3)
        for i in 0..<(gridSize * gridSize) {
            rgb.append(rgba[i * 4])
            rgb.append(rgba[i * 4 + 1])
            rgb.append(rgba[i * 4 + 2])
        }
        return rgb
    }
    
    /// Computes the mean normalized L1 distance (`0.0 ... 1.0`) between two `8x8x3` RGB signatures.
    nonisolated static func signatureDistance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var sumDiff: Int = 0
        for i in 0..<a.count {
            sumDiff += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sumDiff) / (Double(a.count) * 255.0)
    }
}
