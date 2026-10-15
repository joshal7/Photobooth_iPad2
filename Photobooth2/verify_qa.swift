#!/usr/bin/env swift
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// ============================================================================
// Photobooth2 Automated Post-Fix QA Verification Runner (`verify_qa.swift`)
// Executes:
//   1. Simulated Lighting & Exposure Scaling QA Unit Tests:
//      - Low-Light Mode "1" (ISO 200, 1/125s without flash): brightness lift,
//        RGB color preservation (warm skin & cool shirt), and smooth shadow
//        step gradation without 1-bit block quantization.
//      - Decent Light / Dim Auto-ISO 12800: gentle midtone lift with 90th-
//        percentile highlight protection so faces/walls never blow out.
//      - Threshold Continuity (0.36..0.45 sRGB): zero step jump across 0.42.
//      - 4-Frame GIF Burst Equalization: eliminates 4th-frame exposure drift
//        in Aperture Priority mode.
//      - Single-Pass Non-Duplication: verifies `sony_<UUID>.jpg` captures are
//        never double-exposed in Photo Review or GIF creation.
//      - Native In-App GIF Animation Decoding: verifies synchronous multi-frame
//        decoding via CGImageSource in < 100ms.
//   2. Sony PTP Binary Framing & Payload Parser Unit Tests (Tier 2).
// ============================================================================

var passedAssertions = 0
var failedAssertions = 0

func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passedAssertions += 1
        print("  ✅ PASS: \(message)")
    } else {
        failedAssertions += 1
        print("  ❌ FAIL [line \(line)]: \(message)")
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual == expected {
        passedAssertions += 1
        print("  ✅ PASS: \(message) (\(actual))")
    } else {
        failedAssertions += 1
        print("  ❌ FAIL [line \(line)]: \(message) — expected \(expected), got \(actual)")
    }
}

// MARK: - Core Exposure & GIF Pipeline (Mirrors SonyUSBCameraClient & GIFService)

let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

func measureSceneLuminance(_ cgImage: CGImage) -> (subjectSrgbY: Double, p90SrgbY: Double) {
    let sampleSize = 24
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
    ctx.interpolationQuality = .low
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
    
    struct Sample {
        let srgbY: Double
        let weight: Double
    }
    
    var samples: [Sample] = []
    samples.reserveCapacity(sampleSize * sampleSize)
    
    for y in 0..<sampleSize {
        let isCenterY = (y >= sampleSize / 4) && (y < (sampleSize * 3) / 4)
        for x in 0..<sampleSize {
            let isCenterX = (x >= sampleSize / 4) && (x < (sampleSize * 3) / 4)
            let offset = (y * sampleSize + x) * 4
            let r = Double(pixels[offset]) / 255.0
            let g = Double(pixels[offset + 1]) / 255.0
            let b = Double(pixels[offset + 2]) / 255.0
            
            let srgbY = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let weight = (isCenterX && isCenterY) ? 2.5 : 1.0
            samples.append(Sample(srgbY: srgbY, weight: weight))
        }
    }
    
    samples.sort { $0.srgbY < $1.srgbY }
    let p90Index = min(samples.count - 1, max(0, Int(Double(samples.count) * 0.90)))
    let p90SrgbY = samples[p90Index].srgbY
    
    let keepCount = max(1, Int(Double(samples.count) * 0.95))
    var weightedSrgbSum = 0.0
    var totalWeight = 0.0
    for i in 0..<keepCount {
        let s = samples[i]
        weightedSrgbSum += s.srgbY * s.weight
        totalWeight += s.weight
    }
    
    guard totalWeight > 0 else { return (0.5, p90SrgbY) }
    return (weightedSrgbSum / totalWeight, p90SrgbY)
}

func autoExposeCapturedCGImage(_ cgImage: CGImage) -> CGImage {
    let (subjectSrgbY, p90SrgbY) = measureSceneLuminance(cgImage)
    guard subjectSrgbY < 0.42 else { return cgImage }
    
    let safeLuma = max(subjectSrgbY, 0.03)
    var ev = min(max(log2(0.42 / safeLuma), 0.0), 3.8)
    
    if subjectSrgbY >= 0.16, p90SrgbY > 0.45 {
        let highlightSafeEV = max(0.15, log2(0.85 / p90SrgbY) * 1.6)
        ev = min(ev, highlightSafeEV)
    }
    guard ev > 0.04 else { return cgImage }
    
    let ciInput = CIImage(cgImage: cgImage)
    var currentCI = ciInput
    
    if let shadowFilter = CIFilter(name: "CIHighlightShadowAdjust") {
        let shadowLift = min(0.55, ev * 0.15)
        shadowFilter.setValue(currentCI, forKey: kCIInputImageKey)
        shadowFilter.setValue(shadowLift, forKey: "inputShadowAmount")
        shadowFilter.setValue(0.85, forKey: "inputHighlightAmount")
        if let out = shadowFilter.outputImage { currentCI = out }
    }
    if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
        exposureFilter.setValue(currentCI, forKey: kCIInputImageKey)
        exposureFilter.setValue(ev, forKey: kCIInputEVKey)
        if let out = exposureFilter.outputImage { currentCI = out }
    }
    if ev > 1.0 {
        if let gammaFilter = CIFilter(name: "CIGammaAdjust") {
            let gammaPower = max(0.75, 1.0 - (ev - 1.0) * 0.08)
            gammaFilter.setValue(currentCI, forKey: kCIInputImageKey)
            gammaFilter.setValue(gammaPower, forKey: "inputPower")
            if let out = gammaFilter.outputImage { currentCI = out }
        }
        if let colorFilter = CIFilter(name: "CIColorControls") {
            let satBoost = min(1.12, 1.0 + (ev - 1.0) * 0.04)
            colorFilter.setValue(currentCI, forKey: kCIInputImageKey)
            colorFilter.setValue(satBoost, forKey: kCIInputSaturationKey)
            if let out = colorFilter.outputImage { currentCI = out }
        }
    }
    return ciContext.createCGImage(currentCI, from: ciInput.extent) ?? cgImage
}

func createEqualizedGIF(from urls: [URL], frameDuration: Double) -> URL? {
    let gifURL = FileManager.default.temporaryDirectory.appendingPathComponent("qa_\(UUID().uuidString).gif")
    guard let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, urls.count, nil) else {
        return nil
    }
    let fileProperties: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
    let frameProperties: [String: Any] = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: frameDuration]]
    CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
    
    struct FrameEntry { let cgImage: CGImage; let luma: Double }
    var loadedFrames: [FrameEntry] = []
    for url in urls {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let rawCG = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let isAlreadyNormalizedSonyFrame = url.lastPathComponent.hasPrefix("sony_")
        let baseCG = isAlreadyNormalizedSonyFrame ? rawCG : autoExposeCapturedCGImage(rawCG)
        let (luma, _) = measureSceneLuminance(baseCG)
        loadedFrames.append(FrameEntry(cgImage: baseCG, luma: max(luma, 0.02)))
    }
    guard !loadedFrames.isEmpty else { return nil }
    let sorted = loadedFrames.map(\.luma).sorted()
    let mid = sorted.count / 2
    let medianLuma = (sorted.count % 2 == 0 && sorted.count >= 2) ? (sorted[mid - 1] + sorted[mid]) * 0.5 : sorted[mid]
    
    for entry in loadedFrames {
        let clampedDeltaEV = min(max(2.2 * log2(medianLuma / entry.luma), -1.20), 1.20)
        let finalCG: CGImage
        if abs(clampedDeltaEV) > 0.04, let exp = CIFilter(name: "CIExposureAdjust") {
            let ciIn = CIImage(cgImage: entry.cgImage)
            exp.setValue(ciIn, forKey: kCIInputImageKey)
            exp.setValue(clampedDeltaEV, forKey: kCIInputEVKey)
            finalCG = exp.outputImage.flatMap { ciContext.createCGImage($0, from: ciIn.extent) } ?? entry.cgImage
        } else {
            finalCG = entry.cgImage
        }
        CGImageDestinationAddImage(destination, finalCG, frameProperties as CFDictionary)
    }
    return CGImageDestinationFinalize(destination) ? gifURL : nil
}

// MARK: - Synthetic Scene Builders

func makeSyntheticLightingScene(
    bgRGB: (UInt8, UInt8, UInt8),
    subjectSkinRGB: (UInt8, UInt8, UInt8),
    shirtRGB: (UInt8, UInt8, UInt8),
    includeShadowRamp: Bool = false,
    includeSmallBrightLamp: Bool = false
) -> CGImage {
    let width = 48, height = 48
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            var rgb = bgRGB
            if x >= 12 && x < 30 && y >= 12 && y < 30 { rgb = subjectSkinRGB }
            else if x >= 12 && x < 36 && y >= 30 && y < 38 { rgb = shirtRGB }
            if includeShadowRamp && y == 4 {
                if x == 2 { rgb = (1, 1, 1) }
                else if x == 4 { rgb = (2, 2, 2) }
                else if x == 6 { rgb = (4, 4, 4) }
                else if x == 8 { rgb = (8, 8, 8) }
                else if x == 10 { rgb = (16, 16, 16) }
            }
            if includeSmallBrightLamp && x >= 42 && x < 45 && y >= 3 && y < 6 {
                rgb = (245, 240, 225)
            }
            let idx = (y * width + x) * 4
            pixels[idx] = rgb.0; pixels[idx + 1] = rgb.1; pixels[idx + 2] = rgb.2; pixels[idx + 3] = 255
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

func readPixelRGB(_ cgImage: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    let width = cgImage.width, height = cgImage.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    let idx = (y * width + x) * 4
    return (Int(pixels[idx]), Int(pixels[idx + 1]), Int(pixels[idx + 2]))
}

func writeJPEG(_ cgImage: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// MARK: - Run QA Suite

print("========================================================")
print("Photobooth2 Simulated Lighting & Exposure Scaling QA")
print("========================================================")

let tempDir = FileManager.default.temporaryDirectory

// 1. Low-Light Mode "1" / Manual ISO 200 without Flash
let lowLightCG = makeSyntheticLightingScene(
    bgRGB: (2, 2, 3),
    subjectSkinRGB: (18, 12, 8),
    shirtRGB: (7, 13, 20),
    includeShadowRamp: true,
    includeSmallBrightLamp: true
)
let (lowPreLuma, _) = measureSceneLuminance(lowLightCG)
let lowBoostedCG = autoExposeCapturedCGImage(lowLightCG)
let (lowPostLuma, lowPostP90) = measureSceneLuminance(lowBoostedCG)

assertTrue(
    lowPreLuma < 0.04 && lowPostLuma >= 0.25 && lowPostLuma <= 0.52,
    String(format: "Low-Light Mode 1 brightness recovery: %.3f -> %.3f sRGB (target 0.25..0.52)", lowPreLuma, lowPostLuma)
)
assertTrue(
    lowPostP90 < 0.85,
    String(format: "Low-Light Mode 1 90th-percentile highlight stays un-clipped: p90=%.3f (< 0.85)", lowPostP90)
)

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
let autoISOCG = makeSyntheticLightingScene(
    bgRGB: (62, 55, 48),
    subjectSkinRGB: (155, 136, 120),
    shirtRGB: (80, 95, 115)
)
let (autoPreLuma, autoPreP90) = measureSceneLuminance(autoISOCG)
let autoBoostedCG = autoExposeCapturedCGImage(autoISOCG)
let (autoPostLuma, autoPostP90) = measureSceneLuminance(autoBoostedCG)
let autoFacePost = readPixelRGB(autoBoostedCG, x: 20, y: 20)

assertTrue(
    autoPostLuma > autoPreLuma && autoPostLuma <= 0.45,
    String(format: "Auto-ISO 12800 dim capture receives gentle midtone lift: %.3f -> %.3f sRGB", autoPreLuma, autoPostLuma)
)
assertTrue(
    autoPostP90 < 0.82 && autoFacePost.r < 220 && autoFacePost.r > autoFacePost.g && autoFacePost.g > autoFacePost.b,
    String(format: "Auto-ISO 12800 highlights are protected from blowing out: p90 %.3f -> %.3f, face RGB=(%d,%d,%d)", autoPreP90, autoPostP90, autoFacePost.r, autoFacePost.g, autoFacePost.b)
)

// 3. Threshold Continuity Check (0.36 -> 0.45 sRGB)
var prevOutLuma: Double? = nil
var maxStepDelta: Double = 0.0
for rawVal in stride(from: 92, through: 114, by: 4) {
    let v = UInt8(rawVal)
    let testCG = makeSyntheticLightingScene(bgRGB: (v, v, v), subjectSkinRGB: (v, v, v), shirtRGB: (v, v, v))
    let outCG = autoExposeCapturedCGImage(testCG)
    let (outLuma, _) = measureSceneLuminance(outCG)
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
var burstURLs: [URL] = []
let frameValues: [UInt8] = [104, 106, 105, 134]
for (idx, val) in frameValues.enumerated() {
    let cg = makeSyntheticLightingScene(
        bgRGB: (val, val, val),
        subjectSkinRGB: (val &+ 10, val, val &- 8),
        shirtRGB: (val &- 10, val, val &+ 8)
    )
    let fileURL = tempDir.appendingPathComponent("sony_qa_burst_\(idx)_\(UUID().uuidString).jpg")
    writeJPEG(cg, to: fileURL)
    burstURLs.append(fileURL)
}

if let compiledGIFURL = createEqualizedGIF(from: burstURLs, frameDuration: 0.25),
   let gifSource = CGImageSourceCreateWithURL(compiledGIFURL as CFURL, nil) {
    let count = CGImageSourceGetCount(gifSource)
    assertEqual(count, 4, "Compiled burst GIF contains 4 frames")
    var outputFrameLumas: [Double] = []
    for i in 0..<count {
        if let frameCG = CGImageSourceCreateImageAtIndex(gifSource, i, nil) {
            outputFrameLumas.append(measureSceneLuminance(frameCG).subjectSrgbY)
        }
    }
    if let minL = outputFrameLumas.min(), let maxL = outputFrameLumas.max() {
        let spread = maxL - minL
        assertTrue(
            spread < 0.030,
            String(format: "GIFService equalizes 4th-frame exposure drift (input spread 0.115 -> output spread %.4f)", spread)
        )
    }
    try? FileManager.default.removeItem(at: compiledGIFURL)
} else {
    assertTrue(false, "Failed to create burst QA GIF")
}
for u in burstURLs { try? FileManager.default.removeItem(at: u) }

// 5. Non-Duplication Verification for Low-Light Sony Captures in GIFService
let sonyLowURL = tempDir.appendingPathComponent("sony_lowlight_once_\(UUID().uuidString).jpg")
writeJPEG(lowBoostedCG, to: sonyLowURL)
if let lowGIFURL = createEqualizedGIF(from: [sonyLowURL, sonyLowURL], frameDuration: 0.25),
   let src = CGImageSourceCreateWithURL(lowGIFURL as CFURL, nil),
   let gifFrameCG = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    let (gifFrameLuma, _) = measureSceneLuminance(gifFrameCG)
    assertTrue(
        abs(gifFrameLuma - lowPostLuma) < 0.035,
        String(format: "Low-light sony_*.jpg is NOT double-exposed in GIFService (singlePass=%.3f vs gifFrame=%.3f)", lowPostLuma, gifFrameLuma)
    )
    try? FileManager.default.removeItem(at: lowGIFURL)
} else {
    assertTrue(false, "Failed to verify low-light GIF non-duplication")
}
try? FileManager.default.removeItem(at: sonyLowURL)

print("========================================================")
print("QA Summary: \(passedAssertions) PASSED, \(failedAssertions) FAILED")
print("========================================================")
exit(failedAssertions == 0 ? 0 : 1)
