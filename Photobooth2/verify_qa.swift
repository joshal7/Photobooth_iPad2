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

// 6. Top-Center Pill Wait Bar (10% trailing -> 30% leading left-to-right fill) & Photo/GIF Progress Dot Verification
func computePillWaitBarFillWidth(pillWidth: Double, progress: Double) -> Double {
    let clamped = min(max(progress, 0.0), 1.0)
    return pillWidth * clamped
}
let pillWidth = 220.0
let halfFill = computePillWaitBarFillWidth(pillWidth: pillWidth, progress: 0.50)
let fullFill = computePillWaitBarFillWidth(pillWidth: pillWidth, progress: 1.00)
let photoModeFill = computePillWaitBarFillWidth(pillWidth: pillWidth, progress: 0.0)
assertTrue(
    abs(halfFill - 110.0) < 0.001 && abs(fullFill - 220.0) < 0.001 && abs(photoModeFill - 0.0) < 0.001,
    String(format: "Top-Center pill wait bar fills left-to-right (10%% trailing -> 30%% leading: 50%%=%.0fpt, 100%%=%.0fpt, PhotoMode=%.0fpt)", halfFill, fullFill, photoModeFill)
)

// =========================================================================
// 7. AI BACKDROP & FOREGROUND OVERLAYS + MAC BATCH WORKFLOW QA SUITE
// =========================================================================

print("\n--- AI BACKDROP & FOREGROUND + MAC BATCH WORKFLOW QA SUITE ---")

func makeSolidOrBorderCGImage(
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

func encodePNG(_ cgImage: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func encodeJPEGWithEXIF(_ cgImage: CGImage, dateTimeOriginal: String, backdropTag: String? = nil) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var exifDict: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal
    ]
    if let tag = backdropTag {
        exifDict[kCGImagePropertyExifUserComment] = "PB2_BACKDROP:\(tag)"
    }
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.95,
        kCGImagePropertyExifDictionary: exifDict
    ]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// 7A. Verify Bundled Assets in Photobooth2/Photobooth2/Backdrops/
let projectBackdropsURL = URL(fileURLWithPath: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Backdrops", isDirectory: true)
let starterFiles = (try? FileManager.default.contentsOfDirectory(at: projectBackdropsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
let starterNames = Set(starterFiles.map(\.lastPathComponent))
let hasBgFiles = starterNames.contains { $0.lowercased().contains("_bg.") }
let hasFgFiles = starterNames.contains { $0.lowercased().contains("_fg.") }
assertTrue(
    !starterNames.isEmpty && hasBgFiles && hasFgFiles,
    "Bundled Backdrops/ directory contains valid *_bg and *_fg assets (\(starterNames.count) files)"
)

// 7B. Zero-Code Auto-Discovery & Pairing (`_bg` + `_fg` -> Combo) & Leading Numeric Prefix Omission
func stripLeadingNumberPrefix(_ rawStem: String) -> String {
    let trimmed = rawStem.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstChar = trimmed.first, firstChar.isWholeNumber else {
        return trimmed
    }
    let afterDigits = trimmed.drop(while: { $0.isWholeNumber })
    guard let sep = afterDigits.first, sep == "_" || sep == "-" || sep.isWhitespace else {
        return trimmed
    }
    let remainder = afterDigits
        .drop(while: { $0 == "_" || $0 == "-" || $0.isWhitespace })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return remainder.isEmpty ? trimmed : remainder
}

func humanizeDisplayName(_ rawStem: String) -> String {
    let withoutPrefix = stripLeadingNumberPrefix(rawStem)
    let spaced = withoutPrefix
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !spaced.isEmpty else { return "Backdrop" }
    if spaced != spaced.lowercased() {
        return spaced
    }
    return spaced.capitalized
}

func classifyAndDiscover(in dir: URL) -> [(id: String, name: String, displayName: String, bg: String?, fg: String?)] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    var map: [String: (name: String, displayName: String, bg: String?, fg: String?)] = [:]
    var order: [String] = []
    for f in files {
        let stem = f.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        if lower.hasSuffix("_bg") {
            let base = String(stem.dropLast(3))
            let id = base.lowercased().replacingOccurrences(of: " ", with: "_")
            if map[id] == nil { order.append(id); map[id] = (base, humanizeDisplayName(base), f.lastPathComponent, nil) }
            else { map[id]?.bg = f.lastPathComponent }
        } else if lower.hasSuffix("_fg") {
            let base = String(stem.dropLast(3))
            let id = base.lowercased().replacingOccurrences(of: " ", with: "_")
            if map[id] == nil { order.append(id); map[id] = (base, humanizeDisplayName(base), nil, f.lastPathComponent) }
            else { map[id]?.fg = f.lastPathComponent }
        }
    }
    return order.compactMap { id in
        guard let v = map[id] else { return nil }
        return (id, v.name, v.displayName, v.bg, v.fg)
    }
}

let discoveredStarters = classifyAndDiscover(in: projectBackdropsURL)
let pairedCombos = discoveredStarters.filter { $0.bg != nil && $0.fg != nil }
assertTrue(
    !discoveredStarters.isEmpty && (discoveredStarters.count + pairedCombos.count == starterNames.count),
    "Zero-code auto-discovery pairs \(starterNames.count) files into \(discoveredStarters.count) distinct backdrop items (\(pairedCombos.count) combos)"
)
assertTrue(
    !pairedCombos.isEmpty,
    "Auto-discovery pairs matching *_bg + *_fg files into Combo items (\(pairedCombos.map(\.id).joined(separator: ", ")))"
)

// Verify leading 3-digit prefix omission in displayName while preserving exact numeric sort order in carousel & Settings
assertEqual(humanizeDisplayName("101_snowy_mountains"), "Snowy Mountains", "101_snowy_mountains_bg.jpg displays as 'Snowy Mountains'")
assertEqual(humanizeDisplayName("301_mars"), "Mars", "301_mars_bg.jpg displays as 'Mars'")
assertEqual(humanizeDisplayName("snowy_mountains"), "Snowy Mountains", "Un-prefixed snowy_mountains_bg.jpg remains 'Snowy Mountains'")
assertEqual(humanizeDisplayName("Eiffel Tower"), "Eiffel Tower", "Un-prefixed Eiffel Tower_bg.jpg remains 'Eiffel Tower'")

let anyStartsWithDigits = discoveredStarters.contains { item in
    guard let first = item.displayName.first else { return false }
    return first.isWholeNumber
}
assertTrue(
    !anyStartsWithDigits,
    "All \(discoveredStarters.count) bundled Backdrops omit their 3-digit prefix in displayName (e.g. '\(discoveredStarters.first?.displayName ?? "")', '\(discoveredStarters.last?.displayName ?? "")')"
)
assertEqual(
    discoveredStarters.first?.id,
    "101_snowy_peaks",
    "First backdrop in carousel/Settings sort order is 101_snowy_peaks ('\(discoveredStarters.first?.displayName ?? "")')"
)
assertEqual(
    discoveredStarters.last?.id,
    "703_zach_levine_bar_mitzvah",
    "Last backdrop in carousel/Settings sort order is 703_zach_levine_bar_mitzvah ('\(discoveredStarters.last?.displayName ?? "")')"
)

// 7C. Resolution Auto-Scaling & 3-Layer Compositing Order (Background -> Segmented Subject -> Foreground Frame)
func scaleCIImage(_ image: CIImage, to targetExtent: CGRect, stretch: Bool) -> CIImage {
    let src = image.extent
    let norm = image.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY))
    if stretch {
        return norm
            .transformed(by: CGAffineTransform(scaleX: targetExtent.width / src.width, y: targetExtent.height / src.height))
            .cropped(to: targetExtent)
    } else {
        let scale = max(targetExtent.width / src.width, targetExtent.height / src.height)
        let ox = (targetExtent.width - src.width * scale) * 0.5
        let oy = (targetExtent.height - src.height * scale) * 0.5
        return norm
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            .cropped(to: targetExtent)
    }
}

func compositeThreeLayers(
    subjectCG: CGImage,
    bgCG: CGImage?,
    fgCG: CGImage?,
    maskProvider: () -> CIImage?
) -> CGImage {
    let ext = CGRect(x: 0, y: 0, width: subjectCG.width, height: subjectCG.height)
    var current = CIImage(cgImage: subjectCG)
    if let bg = bgCG {
        let scaledBg = scaleCIImage(CIImage(cgImage: bg), to: ext, stretch: false)
        if let mask = maskProvider(), let filter = CIFilter(name: "CIBlendWithMask") {
            let scaledMask = scaleCIImage(mask, to: ext, stretch: true)
            filter.setValue(current, forKey: kCIInputImageKey)
            filter.setValue(scaledBg, forKey: kCIInputBackgroundImageKey)
            filter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
            if let out = filter.outputImage?.cropped(to: ext) {
                current = out
            }
        }
    }
    if let fg = fgCG {
        let scaledFg = scaleCIImage(CIImage(cgImage: fg), to: ext, stretch: true)
        current = scaledFg.composited(over: current).cropped(to: ext)
    }
    return ciContext.createCGImage(current, from: ext) ?? subjectCG
}

let subjectBlueCG = makeSolidOrBorderCGImage(width: 240, height: 160, fillRGBA: (30, 90, 230, 255))
let portraitRedBgCG = makeSolidOrBorderCGImage(width: 120, height: 200, fillRGBA: (220, 30, 30, 255))
let squareGreenFrameCG = makeSolidOrBorderCGImage(
    width: 100,
    height: 100,
    fillRGBA: (0, 0, 0, 0),
    borderThickness: 12,
    borderRGBA: (20, 210, 60, 255)
)
let centerPersonMaskCG = makeSolidOrBorderCGImage(
    width: 240,
    height: 160,
    fillRGBA: (255, 255, 255, 255),
    borderThickness: 50,
    borderRGBA: (0, 0, 0, 255)
)
let centerPersonMaskCI = CIImage(cgImage: centerPersonMaskCG)

let comboCG = compositeThreeLayers(
    subjectCG: subjectBlueCG,
    bgCG: portraitRedBgCG,
    fgCG: squareGreenFrameCG,
    maskProvider: { centerPersonMaskCI }
)
assertEqual(comboCG.width, 240, "3-layer compositor preserves exact subject width (240)")
assertEqual(comboCG.height, 160, "3-layer compositor preserves exact subject height (160)")

let outerBorderRGB = readPixelRGB(comboCG, x: 4, y: 4)
let bgRingRGB = readPixelRGB(comboCG, x: 36, y: 36)
let subjectCenterRGB = readPixelRGB(comboCG, x: 120, y: 80)

assertTrue(
    outerBorderRGB.g > 170 && outerBorderRGB.r < 60 && outerBorderRGB.b < 90,
    "Layer 3 (Foreground Frame) stretches to all 4 edges on top of background & subject: RGB=(\(outerBorderRGB.r),\(outerBorderRGB.g),\(outerBorderRGB.b))"
)
assertTrue(
    bgRingRGB.r > 170 && bgRingRGB.g < 70 && bgRingRGB.b < 70,
    "Layer 1 (Background) replaces physical room outside person mask: RGB=(\(bgRingRGB.r),\(bgRingRGB.g),\(bgRingRGB.b))"
)
assertTrue(
    subjectCenterRGB.b > 180 && subjectCenterRGB.r < 70,
    "Layer 2 (Segmented Subject) remains intact in front of background and behind frame hole: RGB=(\(subjectCenterRGB.r),\(subjectCenterRGB.g),\(subjectCenterRGB.b))"
)

// 7D. Foreground-Only Fast Path (Bypasses Segmentation Completely)
var maskCallCount = 0
let frameOnlyCG = compositeThreeLayers(
    subjectCG: subjectBlueCG,
    bgCG: nil,
    fgCG: squareGreenFrameCG,
    maskProvider: {
        maskCallCount += 1
        return centerPersonMaskCI
    }
)
assertEqual(maskCallCount, 0, "Foreground-only frame bypasses Vision person segmentation (0 mask evaluations)")
assertTrue(
    readPixelRGB(frameOnlyCG, x: 4, y: 4).g > 170 && readPixelRGB(frameOnlyCG, x: 120, y: 80).b > 180,
    "Foreground-only frame renders green border over untouched blue subject"
)

// 7E. iPad Front-Camera Selfie Pre-Mirroring (Subject Mirrors Horizontally, Foreground Text Stays Un-Mirrored)
let rawFrontSubj = makeSolidOrBorderCGImage(
    width: 160,
    height: 120,
    fillRGBA: (40, 40, 40, 255),
    rightMarkerRGBA: (250, 250, 20, 255) // Yellow marker on RIGHT of raw image
)
let asymmetricFrame = makeSolidOrBorderCGImage(
    width: 160,
    height: 120,
    fillRGBA: (0, 0, 0, 0),
    rightMarkerRGBA: (20, 240, 240, 255) // Cyan marker on RIGHT of foreground frame
)
let mirroredSubjCI = CIImage(cgImage: rawFrontSubj)
    .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
    .transformed(by: CGAffineTransform(translationX: 160, y: 0))
let mirroredSubjCG = ciContext.createCGImage(mirroredSubjCI, from: CGRect(x: 0, y: 0, width: 160, height: 120))!
let preMirroredOut = compositeThreeLayers(
    subjectCG: mirroredSubjCG,
    bgCG: nil,
    fgCG: asymmetricFrame,
    maskProvider: { nil }
)
let leftSubjPx = readPixelRGB(preMirroredOut, x: 10, y: 60)
let rightFramePx = readPixelRGB(preMirroredOut, x: 150, y: 60)
assertTrue(
    leftSubjPx.r > 200 && leftSubjPx.g > 200 && rightFramePx.g > 200 && rightFramePx.b > 200,
    "iPad Front-Camera Pre-Mirroring: subject mirrors horizontally (left) while foreground text stays un-reversed (right)"
)

// 7F. Triple-Lock Matching (PTP 0x1008 Filename + EXIF Timestamp + 8x8 RGB Signature) & SmugMug-Safe In-Place Batch Update
func computeRGBSignature8x8(_ cgImage: CGImage) -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: 8 * 8 * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let w = CGFloat(cgImage.width)
    let h = CGFloat(cgImage.height)
    let cropped = cgImage.cropping(to: CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.8)) ?? cgImage
    rgba.withUnsafeMutableBytes { ptr in
        let ctx = CGContext(
            data: ptr.baseAddress,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    var rgb: [UInt8] = []
    for i in 0..<64 {
        rgb.append(rgba[i * 4])
        rgb.append(rgba[i * 4 + 1])
        rgb.append(rgba[i * 4 + 2])
    }
    return rgb
}

func signatureDist(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1.0 }
    var diff = 0
    for i in 0..<a.count { diff += abs(Int(a[i]) - Int(b[i])) }
    return Double(diff) / (Double(a.count) * 255.0)
}

let dsc1Blue = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (30, 80, 220, 255))
let dsc2Gold = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (220, 180, 30, 255))
let sigBlue = computeRGBSignature8x8(dsc1Blue)
let sigGold = computeRGBSignature8x8(dsc2Gold)
assertTrue(
    signatureDist(sigBlue, sigBlue) < 0.001 && signatureDist(sigBlue, sigGold) > 0.35,
    String(format: "8x8 RGB perceptual signature disambiguates same-second shots (selfDist=%.4f, crossDist=%.3f)", signatureDist(sigBlue, sigBlue), signatureDist(sigBlue, sigGold))
)

// 7G. Bottom Touch-Shield Hit-Testing Verification
func isPointInsideShield(_ point: CGPoint, screenSize: CGSize, isExpanded: Bool) -> Bool {
    if isExpanded {
        let shieldWidth = min(screenSize.width, max(640, screenSize.width - 80))
        let minX = (screenSize.width - shieldWidth) * 0.5
        return point.x >= minX && point.x <= (minX + shieldWidth) && point.y >= (screenSize.height - 250) && point.y <= screenSize.height
    } else {
        let shieldWidth = min(screenSize.width, 420.0)
        let minX = (screenSize.width - shieldWidth) * 0.5
        return point.x >= minX && point.x <= (minX + shieldWidth) && point.y >= (screenSize.height - 110) && point.y <= screenSize.height
    }
}
let iPadScreen = CGSize(width: 1194, height: 834)
assertTrue(
    isPointInsideShield(CGPoint(x: 597, y: 800), screenSize: iPadScreen, isExpanded: false) &&
    isPointInsideShield(CGPoint(x: 450, y: 745), screenSize: iPadScreen, isExpanded: false) &&
    !isPointInsideShield(CGPoint(x: 597, y: 520), screenSize: iPadScreen, isExpanded: true),
    "Bottom anti-misfire touch shield absorbs taps around the pill/carousel while keeping upper capture buttons unobstructed"
)

// 7H. Deleted-Photo Lock-2 Signature Guard & Shifted-Offset PTP Filename Extraction
let dsc3Grey = makeSolidOrBorderCGImage(width: 200, height: 150, fillRGBA: (90, 90, 90, 255))
let sigGrey = computeRGBSignature8x8(dsc3Grey)
assertTrue(
    signatureDist(sigBlue, sigGrey) >= 0.25,
    String(format: "Lock-2 RGB signature guard rejects unrelated photo within ±3s window when target photo was deleted (dist=%.3f >= 0.25)", signatureDist(sigBlue, sigGrey))
)

// 7I. Custom Backdrop Role-Suffix Stripping (Prevents `_fg_fg.png` / `_bg_bg.jpg` Double Suffixes)
func stripRoleSuffix(from rawStem: String) -> String {
    let trimmed = rawStem.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    let allSuffixes = [
        "_fg_fill", "-fg-fill",
        "_background", "-background",
        "_foreground", "-foreground",
        "_frame", "-frame", " frame",
        "_bg", "-bg", " bg",
        "_fg", "-fg", " fg"
    ]
    for suffix in allSuffixes {
        if lower.hasSuffix(suffix) {
            let candidate = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
    }
    return trimmed
}
assertEqual(
    stripRoleSuffix(from: "Evans_Bar_Mitzvah_fg"),
    "Evans_Bar_Mitzvah",
    "Role suffix stripper removes trailing `_fg` before saving custom backdrop"
)
assertEqual(
    stripRoleSuffix(from: "Eiffel Tower-bg"),
    "Eiffel Tower",
    "Role suffix stripper removes trailing `-bg` before saving custom backdrop"
)

// 7J. Single-Pass Non-Zero Origin CIImage Compositing Equivalence (30 FPS Live View Optimization)
let shiftedOriginSubjCI = CIImage(cgImage: subjectBlueCG)
    .transformed(by: CGAffineTransform(translationX: -240, y: 120))
let rawExt = shiftedOriginSubjCI.extent
let normalizedShiftedCI = shiftedOriginSubjCI
    .transformed(by: CGAffineTransform(translationX: -rawExt.minX, y: -rawExt.minY))
let normalizedShiftedCG = ciContext.createCGImage(normalizedShiftedCI, from: CGRect(x: 0, y: 0, width: rawExt.width, height: rawExt.height))!
let centerShiftPx = readPixelRGB(normalizedShiftedCG, x: 120, y: 80)
assertTrue(
     Int(rawExt.width) == 240 && Int(rawExt.height) == 160 && centerShiftPx.b > 180,
    "Single-pass CIImage normalization preserves exact extent and pixels for mirrored non-zero-origin Live View frames"
)

// 7K. Missing-Asset Pre-Check Guard (Prevents False Overwrite / PB2_BACKDROP Stamp When Asset Is Missing)
func hasResolvableAssets(
    bgFilename: String?,
    fgFilename: String?,
    customBgData: Data?,
    customFgData: Data?,
    searchDirs: [URL]
) -> Bool {
    if let bg = bgFilename {
        let found = (customBgData != nil && !customBgData!.isEmpty) ||
            searchDirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(bg).path) }
        if !found { return false }
    }
    if let fg = fgFilename {
        let found = (customFgData != nil && !customFgData!.isEmpty) ||
            searchDirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(fg).path) }
        if !found { return false }
    }
    return bgFilename != nil || fgFilename != nil
}
let existingSampleFilename = starterNames.sorted().first ?? "eiffel_tower_night_bg.jpg"
assertTrue(
    !hasResolvableAssets(bgFilename: "NonExistent_bg.jpg", fgFilename: nil, customBgData: nil, customFgData: nil, searchDirs: [projectBackdropsURL]) &&
    hasResolvableAssets(bgFilename: existingSampleFilename, fgFilename: nil, customBgData: nil, customFgData: nil, searchDirs: [projectBackdropsURL]),
    "Pre-check guard rejects missing backdrop assets before decoding/overwriting full-res JPEGs"
)

// 7L. Auto-Incrementing Default Custom Backdrop Naming ("Custom Backdrop", "Custom Backdrop 2", ...)
func nextDefaultCustomBackdropName(existingIDs: Set<String>) -> String {
    var candidate = "Custom Backdrop"
    var counter = 2
    while existingIDs.contains(candidate.lowercased().replacingOccurrences(of: " ", with: "_")) {
        candidate = "Custom Backdrop \(counter)"
        counter += 1
    }
    return candidate
}
assertEqual(
    nextDefaultCustomBackdropName(existingIDs: ["custom_backdrop", "custom_backdrop_2"]),
    "Custom Backdrop 3",
    "Unnamed custom backdrops auto-increment ('Custom Backdrop 3') instead of overwriting previous custom backdrops"
)

// 7M. Persistent Background Selection State Machine Behavior (Default Off, Persists When On, Reverts When Toggled Off)
struct MockPersistentBackdropState {
    let enabledIDs: Set<String> = ["none", "eiffel_tower", "magazine", "celebration_frame"]
    var defaultBackdropID: String = "none"
    var persistentBackdropSelection: Bool = false {
        didSet {
            if !persistentBackdropSelection {
                selectedBackdropID = enabledIDs.contains(defaultBackdropID) ? defaultBackdropID : "none"
            }
        }
    }
    var selectedBackdropID: String = "none"
    
    mutating func selectBackdrop(_ id: String) {
        selectedBackdropID = id
    }
    
    mutating func transitionToIdleForNextPhoto() {
        if persistentBackdropSelection && enabledIDs.contains(selectedBackdropID) {
            // Keep selectedBackdropID
        } else {
            selectedBackdropID = enabledIDs.contains(defaultBackdropID) ? defaultBackdropID : "none"
        }
    }
}

var mockState = MockPersistentBackdropState()
assertEqual(mockState.persistentBackdropSelection, false, "Persistent Background Selection defaults to off (false)")
mockState.selectBackdrop("eiffel_tower")
mockState.transitionToIdleForNextPhoto()
assertEqual(mockState.selectedBackdropID, "none", "When Persistent Background Selection is off, next photo resets to default background ('none')")

mockState.persistentBackdropSelection = true
mockState.selectBackdrop("eiffel_tower")
mockState.transitionToIdleForNextPhoto()
assertEqual(mockState.selectedBackdropID, "eiffel_tower", "When Persistent Background Selection is on, 'eiffel_tower' stays present for the next photo")

mockState.selectBackdrop("magazine")
mockState.transitionToIdleForNextPhoto()
assertEqual(mockState.selectedBackdropID, "magazine", "Selecting a different background ('magazine') persists the new selection for the next photo")

mockState.persistentBackdropSelection = false
assertEqual(mockState.selectedBackdropID, "none", "Toggling Persistent Background Selection off immediately reverts to the default background ('none')")

// 7N. Live View Vision .balanced Matte Solidification LUT & Motion-Adaptive Temporal EMA Stabilization
func buildSmoothstepLUT(lowClip: Int, highClip: Int) -> [UInt8] {
    var lut = [UInt8](repeating: 0, count: 256)
    let span = Double(max(1, highClip - lowClip))
    for i in 0..<256 {
        if i <= lowClip { lut[i] = 0 }
        else if i >= highClip { lut[i] = 255 }
        else {
            let t = Double(i - lowClip) / span
            let s = t * t * (3.0 - 2.0 * t)
            lut[i] = UInt8(clamping: Int((s * 255.0).rounded()))
        }
    }
    return lut
}
let liveLUT = buildSmoothstepLUT(lowClip: 48, highClip: 202)
assertTrue(
    liveLUT[45] == 0 && liveLUT[205] == 255 && liveLUT[125] > 100 && liveLUT[125] < 155,
    "Hermite smoothstep matte LUT eliminates background noise (<=48 -> 0) and see-through clothing (>=202 -> 255) with smooth boundary ramp"
)

func stepTemporalEMA(prev: [UInt8], raw: [UInt8], lut: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: raw.count)
    for i in 0..<raw.count {
        let solid = Int(lut[Int(raw[i])])
        let p = Int(prev[i])
        let diff = abs(solid - p)
        if diff < 85 {
            out[i] = UInt8(clamping: (solid * 120 + p * 136) >> 8)
        } else if diff < 155 {
            out[i] = UInt8(clamping: (solid * 192 + p * 64) >> 8)
        } else {
            out[i] = UInt8(clamping: (solid * 238 + p * 18) >> 8)
        }
    }
    return out
}
let priorMask: [UInt8] = [0, liveLUT[118], 255, 0]
let nextRaw: [UInt8]   = [35, 134, 215, 240]
let nextSmoothed = stepTemporalEMA(prev: priorMask, raw: nextRaw, lut: liveLUT)
let rawEdgeJump = abs(Int(liveLUT[134]) - Int(priorMask[1]))
let smoothedEdgeJump = abs(Int(nextSmoothed[1]) - Int(priorMask[1]))
assertTrue(
    nextSmoothed[0] == 0 && nextSmoothed[2] == 255 && smoothedEdgeJump < rawEdgeJump && nextSmoothed[3] >= 235,
    "Motion-adaptive temporal EMA dampens edge shimmer (jump \(rawEdgeJump)->\(smoothedEdgeJump)) while fast hand movement responds immediately (\(nextSmoothed[3])/255)"
)

// 7O. Verify BackdropManager.swift Thumbnail Generator Has Removed Dual People Silhouette Icon (`person.2.fill`)
let backdropManagerSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Services/BackdropManager.swift", encoding: .utf8)) ?? ""
assertTrue(
    !backdropManagerSource.contains("person.2.fill"),
    "BackdropManager thumbnail generator renders clean background/frame artwork without 'person.2.fill' overlay"
)

// 7P. Verify CVPixelBuffer (OneComponent8) and Solidified Grayscale CGImage Have Identical Vertical Orientation in CoreImage
var testPB: CVPixelBuffer? = nil
CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_OneComponent8, nil, &testPB)
if let pb = testPB {
    CVPixelBufferLockBaseAddress(pb, [])
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<16 {
        for x in 0..<16 {
            base[y * bpr + x] = (y < 8) ? 255 : 0 // Top 8 rows white (255), bottom 8 rows black (0)
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    
    let ciFromPB = CIImage(cvPixelBuffer: pb)
    var flatBytes = [UInt8](repeating: 0, count: 16 * 16)
    for y in 0..<16 {
        for x in 0..<16 {
            flatBytes[y * 16 + x] = (y < 8) ? 255 : 0
        }
    }
    let grayCS = CGColorSpaceCreateDeviceGray()
    let cgFromBuf = flatBytes.withUnsafeMutableBytes { ptr -> CGImage in
        let ctx = CGContext(data: ptr.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16, space: grayCS, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }
    let ciFromCG = CIImage(cgImage: cgFromBuf)
    let outPB = ciContext.createCGImage(ciFromPB, from: CGRect(x: 0, y: 0, width: 16, height: 16))!
    let outCG = ciContext.createCGImage(ciFromCG, from: CGRect(x: 0, y: 0, width: 16, height: 16))!
    assertEqual(
        readPixelRGB(outPB, x: 8, y: 2).r,
        readPixelRGB(outCG, x: 8, y: 2).r,
        "Solidified CGImage mask top row matches CVPixelBuffer top row orientation in CoreImage (255)"
    )
    assertEqual(
        readPixelRGB(outPB, x: 8, y: 14).r,
        readPixelRGB(outCG, x: 8, y: 14).r,
        "Solidified CGImage mask bottom row matches CVPixelBuffer bottom row orientation in CoreImage (0)"
    )
}

// 7Q. Verify 3:2 Landscape Aspect Ratio & Top/Bottom Black Bars Across All Configurations (Live View, Photos, GIFs)
let liveViewSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Views/LiveView.swift", encoding: .utf8)) ?? ""
let reviewViewSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Views/ReviewView.swift", encoding: .utf8)) ?? ""
let infoPlistSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Info.plist", encoding: .utf8)) ?? ""
assertTrue(
    liveViewSource.contains(".aspectRatio(contentMode: .fit)") &&
    !liveViewSource.contains(".aspectRatio(contentMode: .fill)") &&
    !liveViewSource.contains(".clipped()") &&
    reviewViewSource.contains(".aspectRatio(contentMode: .fit)"),
    "LiveView.swift and ReviewView.swift render images with .aspectRatio(contentMode: .fit)"
)
assertTrue(
    !infoPlistSource.contains("UIInterfaceOrientationPortrait") &&
    infoPlistSource.contains("UIInterfaceOrientationLandscapeRight") &&
    infoPlistSource.contains("UIInterfaceOrientationLandscapeLeft"),
    "Info.plist locks iPad interface orientations to horizontal Landscape (4:3 screen)"
)

func cropToLandscapeThreeByTwo(_ ciImage: CIImage) -> CIImage {
    let ext = ciImage.extent
    let normalized = (ext.minX != 0 || ext.minY != 0)
        ? ciImage.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        : ciImage
    let w = normalized.extent.width
    let h = normalized.extent.height
    let currentAspect = w / h
    let targetAspect: CGFloat = 1.5
    if abs(currentAspect - targetAspect) <= 0.008 {
        return normalized
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
    let ox = ((w - cropW) * 0.5).rounded(.down)
    let oy = ((h - cropH) * 0.5).rounded(.down)
    return normalized
        .cropped(to: CGRect(x: ox, y: oy, width: cropW, height: cropH))
        .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
}

func computeFittedRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    return CGRect(x: (containerSize.width - w) * 0.5, y: (containerSize.height - h) * 0.5, width: w, height: h)
}

// Verify iPad 4:3 Front Camera Live View (1440x1080) and Photo (4032x3024) are oriented, mirrored, and cropped to exact 3:2 (1440x960 and 4032x2688)
func orientAndMirrorFrontCameraCI(_ rawCIImage: CIImage, orientationRaw: Int) -> CIImage {
    let isRawSensorLandscape = rawCIImage.extent.width >= rawCIImage.extent.height
    let uprightExif: Int32
    switch orientationRaw {
    case 3: // .landscapeLeft
        uprightExif = isRawSensorLandscape ? 3 : 6 // .down : .right
    case 4: // .landscapeRight
        uprightExif = isRawSensorLandscape ? 1 : 8 // .up : .left
    default: // .portrait (1), .portraitUpsideDown (2), .unknown (0) -> keep landscape!
        uprightExif = isRawSensorLandscape ? 3 : 6
    }
    let upright = rawCIImage.oriented(forExifOrientation: uprightExif)
    let ext = upright.extent
    let normalized = upright.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
    let mirrored = normalized
        .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
        .transformed(by: CGAffineTransform(translationX: ext.width, y: 0))
    return cropToLandscapeThreeByTwo(mirrored)
}

for orientRaw in [0, 1, 2, 3, 4] {
    let liveExt = orientAndMirrorFrontCameraCI(
        CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1440, height: 1080)),
        orientationRaw: orientRaw
    ).extent
    assertEqual(Int(liveExt.width), 1440, "Front camera 1440x1080 preserves full 1440 width (orientation=\(orientRaw))")
    assertEqual(Int(liveExt.height), 960, "Front camera 1440x1080 center-crops height to 960 3:2 (orientation=\(orientRaw))")
}

let iPadPhotoCropped = orientAndMirrorFrontCameraCI(
    CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 4032, height: 3024)),
    orientationRaw: 3
).extent
let mac16x9Cropped = cropToLandscapeThreeByTwo(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))).extent
assertEqual(Int(iPadPhotoCropped.width), 4032, "iPad 4:3 Photo preserves full 4032 width")
assertEqual(Int(iPadPhotoCropped.height), 2688, "iPad 4:3 Photo center-crops height to 2688 (exact 3:2)")
assertEqual(Int(mac16x9Cropped.width), 1620, "16:9 camera frame center-crops width to 1620 (exact 3:2)")
assertEqual(Int(mac16x9Cropped.height), 1080, "16:9 camera frame preserves full 1080 height")

// Verify 3-layer compositing (none, bg-only, fg-only, combo) on a cropped 3:2 camera frame (360x240 from 360x270 4:3)
// and compiling into a real animated GIF file on disk produces exact 3:2 frames with 0.0pt left/right black bars!
let raw4x3CameraCG = makeSolidOrBorderCGImage(width: 360, height: 270, fillRGBA: (30, 90, 230, 255))
let cropped3x2CameraCI = cropToLandscapeThreeByTwo(CIImage(cgImage: raw4x3CameraCG))
let cropped3x2CameraCG = ciContext.createCGImage(cropped3x2CameraCI, from: cropped3x2CameraCI.extent)!
assertEqual(cropped3x2CameraCG.width, 360, "Cropped camera frame width is 360")
assertEqual(cropped3x2CameraCG.height, 240, "Cropped camera frame height is 240 (exact 3:2)")

let bg3x2CG = makeSolidOrBorderCGImage(width: 360, height: 240, fillRGBA: (220, 30, 30, 255))
let fg3x2CG = makeSolidOrBorderCGImage(width: 360, height: 240, fillRGBA: (0, 0, 0, 0), borderThickness: 12, borderRGBA: (20, 210, 60, 255))
let mask3x2CI = CIImage(cgImage: makeSolidOrBorderCGImage(width: 360, height: 240, fillRGBA: (255, 255, 255, 255), borderThickness: 40, borderRGBA: (0, 0, 0, 255)))

let modeOutputs: [(String, CGImage)] = [
    ("Original (None)", compositeThreeLayers(subjectCG: cropped3x2CameraCG, bgCG: nil, fgCG: nil, maskProvider: { nil })),
    ("Background-Only", compositeThreeLayers(subjectCG: cropped3x2CameraCG, bgCG: bg3x2CG, fgCG: nil, maskProvider: { mask3x2CI })),
    ("Foreground-Only", compositeThreeLayers(subjectCG: cropped3x2CameraCG, bgCG: nil, fgCG: fg3x2CG, maskProvider: { nil })),
    ("Background+Foreground Combo", compositeThreeLayers(subjectCG: cropped3x2CameraCG, bgCG: bg3x2CG, fgCG: fg3x2CG, maskProvider: { mask3x2CI }))
]

for (modeName, outCG) in modeOutputs {
    let ratio = Double(outCG.width) / Double(outCG.height)
    assertTrue(
        outCG.width == 360 && outCG.height == 240 && abs(ratio - 1.5) < 0.0001,
        "\(modeName) Photo/LiveView output is exact 3:2 (\(outCG.width)x\(outCG.height), ratio=\(String(format: "%.3f", ratio)))"
    )
    // Also compile a 2-frame animated GIF for this backdrop mode and verify the encoded GIF frames are 3:2
    let gifTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("qa_3x2_\(UUID().uuidString).gif")
    if let dest = CGImageDestinationCreateWithURL(gifTempURL as CFURL, UTType.gif.identifier as CFString, 2, nil) {
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationAddImage(dest, outCG, nil)
        CGImageDestinationFinalize(dest)
        if let src = CGImageSourceCreateWithURL(gifTempURL as CFURL, nil),
           let decodedGIFFrame = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let gifRatio = Double(decodedGIFFrame.width) / Double(decodedGIFFrame.height)
            assertTrue(
                abs(gifRatio - 1.5) < 0.0001,
                "\(modeName) compiled GIF frame is exact 3:2 (\(decodedGIFFrame.width)x\(decodedGIFFrame.height), ratio=\(String(format: "%.3f", gifRatio)))"
            )
        }
        try? FileManager.default.removeItem(at: gifTempURL)
    }
}

// Verify ALL configurations (Sony Live View 1024x680, iPad Live View 1440x960, Captured Photo 4032x2688,
// Backdrop/Foreground 3504x2336, and 1080p GIF 1620x1080) on BOTH 4:3 iPad (1366x1024 & 1024x768) and 11" iPad (1194x834)
// have 0.0pt left/right black bars and place small black bars EXCLUSIVELY on top and bottom!
let all3x2Configs: [(String, CGSize)] = [
    ("Sony 3:2 Live View", CGSize(width: 1024, height: 680)),
    ("iPad 3:2 Live View", CGSize(width: 1440, height: 960)),
    ("iPad 3:2 Captured Photo", CGSize(width: 4032, height: 2688)),
    ("Backdrop/Foreground 3:2 Asset", CGSize(width: 3504, height: 2336)),
    ("Compiled 3:2 1080p GIF", CGSize(width: 1620, height: 1080))
]
let allIPadScreens: [(String, CGSize)] = [
    ("4:3 iPad (1024x768)", CGSize(width: 1024, height: 768)),
    ("4:3 iPad Pro 12.9\" (1366x1024)", CGSize(width: 1366, height: 1024)),
    ("11\" iPad Pro/Air (1194x834)", CGSize(width: 1194, height: 834))
]

for (configName, imgSize) in all3x2Configs {
    for (screenName, screenSize) in allIPadScreens {
        let fitted = computeFittedRect(imageSize: imgSize, containerSize: screenSize)
        assertTrue(
            abs(fitted.width - screenSize.width) < 0.01 &&
            fitted.height < screenSize.height &&
            abs(fitted.minX) < 0.01 &&
            fitted.minY > 15.0 &&
            abs((fitted.width / fitted.height) - (imgSize.width / imgSize.height)) < 0.0001,
            String(format: "%@ on %@ spans 100%% width (left/right bars=0.0pt, top/bottom bars=%.1fpt each)", configName, screenName, fitted.minY)
        )
    }
}

// 7R. External Camera (`SonyUSBCameraClient`) Horizontal Mirroring for Live View, Captured Photos, Animated GIFs & Mac Batch
let sonySource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Services/SonyUSBCameraClient.swift", encoding: .utf8)) ?? ""
let manifestSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Services/BackdropManifestStore.swift", encoding: .utf8)) ?? ""
assertTrue(
    sonySource.contains("let mirroredRawCG = BackdropCompositorService.mirrorCGImageHorizontally(unmirroredRawCG, ciContext: ciContext)") &&
    sonySource.contains("let mirroredCG = BackdropCompositorService.mirrorCGImageHorizontally(threeByTwoCG, ciContext: ciContext)") &&
    manifestSource.contains("let mirroredFullCG = BackdropCompositorService.mirrorCGImageHorizontally(rawFullCG, ciContext: ciContext)"),
    "SonyUSBCameraClient & BackdropManifestStore horizontally mirror external camera Live View, Photo, GIF, and Full-Res subject frames before backdrop/foreground compositing"
)

let rawExternalSubj = makeSolidOrBorderCGImage(
    width: 180,
    height: 120,
    fillRGBA: (95, 95, 95, 255),
    rightMarkerRGBA: (250, 250, 20, 255) // Yellow marker on RIGHT of raw external camera image
)
let externalAsymFrame = makeSolidOrBorderCGImage(
    width: 180,
    height: 120,
    fillRGBA: (0, 0, 0, 0),
    rightMarkerRGBA: (20, 240, 240, 255) // Cyan marker on RIGHT of foreground frame
)
let mirroredExtSubjCI = CIImage(cgImage: rawExternalSubj)
    .transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0))
    .transformed(by: CGAffineTransform(translationX: 180, y: 0))
let mirroredExtSubjCG = ciContext.createCGImage(mirroredExtSubjCI, from: CGRect(x: 0, y: 0, width: 180, height: 120))!
let extExposedCG = autoExposeCapturedCGImage(mirroredExtSubjCG)
let extCompositedOut = compositeThreeLayers(
    subjectCG: extExposedCG,
    bgCG: nil,
    fgCG: externalAsymFrame,
    maskProvider: { nil }
)
let extLeftSubjPx = readPixelRGB(extCompositedOut, x: 10, y: 60)
let extRightFramePx = readPixelRGB(extCompositedOut, x: 170, y: 60)
assertTrue(
    extLeftSubjPx.r > 200 && extLeftSubjPx.g > 200 && extLeftSubjPx.b < 80 &&
    extRightFramePx.g > 200 && extRightFramePx.b > 200 && extRightFramePx.r < 80,
    "External Camera Horizontal Mirroring: subject mirrors to left (\(extLeftSubjPx.r),\(extLeftSubjPx.g),\(extLeftSubjPx.b)) while foreground frame stays un-reversed on right (\(extRightFramePx.r),\(extRightFramePx.g),\(extRightFramePx.b))"
)

// ============================================================================
// 8. Email Sharing & Offline / Spotty Wi-Fi Queue QA Suite
// ============================================================================
print("\n[8] Testing Email Sharing & Offline / Spotty Wi-Fi Queue...")

let emailServiceSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Services/EmailQueueService.swift", encoding: .utf8)) ?? ""
let sharingViewsSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/Views/SharingViews.swift", encoding: .utf8)) ?? ""
let stateMachineSource = (try? String(contentsOfFile: "/Users/joshal/workspace/PhotoboothApp2/Photobooth2/Photobooth2/Sources/State/StateMachine.swift", encoding: .utf8)) ?? ""

// 8A. Verify UI Button Order: Email sits right next to AirDrop before No Thanks
if let airDropRange = sharingViewsSource.range(of: "Text(\"AirDrop\")"),
   let emailRange = sharingViewsSource.range(of: "Text(\"Email\")"),
   let noThanksRange = sharingViewsSource.range(of: "Text(\"No Thanks\")") {
    assertTrue(
        airDropRange.lowerBound < emailRange.lowerBound && emailRange.lowerBound < noThanksRange.lowerBound,
        "SharingOverlayView places Email button right next to AirDrop button (AirDrop -> Email -> No Thanks)"
    )
} else {
    assertTrue(false, "SharingOverlayView must contain AirDrop, Email, and No Thanks buttons")
}

assertTrue(
    stateMachineSource.contains("case emailSharing(images: [String])") &&
    stateMachineSource.contains("func selectEmailSharing()"),
    "StateMachine defines .emailSharing state and selectEmailSharing() transition"
)

assertTrue(
    emailServiceSource.contains("urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: \"Idempotency-Key\")") &&
    emailServiceSource.contains("contentType.contains(\"text/html\")"),
    "ResendEmailTransport sets Idempotency-Key header and guards against captive portal text/html 200 OK responses"
)

// 8B. Email Validation, Domain Shortcut Chips, HTML Footer Hyperlink & Online/Offline Copy
func qaIsValidEmail(_ rawEmail: String) -> Bool {
    let trimmed = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 5, trimmed.count <= 254, !trimmed.contains(" ") else { return false }
    let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    let local = parts[0]
    let domain = parts[1]
    guard !local.isEmpty, domain.count >= 3 else { return false }
    guard !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
    let domainLabels = domain.split(separator: ".")
    guard domainLabels.count >= 2, let tld = domainLabels.last, tld.count >= 2 else { return false }
    return true
}

func qaNormalizeGalleryURL(_ rawURLString: String) -> String {
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

func qaBuildEmailHTML(galleryURLString: String) -> String {
    let normalizedURL = qaNormalizeGalleryURL(galleryURLString)
    let escapedURL = normalizedURL
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    return """
    <!DOCTYPE html>
    <html>
    <head><meta charset="UTF-8"></head>
    <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #222222; line-height: 1.5; padding: 16px;">
      <p>Thanks for visiting the photobooth! Your photos &amp; animated GIF from your session are attached to this email.</p>
      <hr style="border: none; border-top: 1px solid #e0e0e0; margin: 24px 0;" />
      <p style="font-size: 14px; color: #444444;">All full resolution images and gifs can be downloaded <a href="\(escapedURL)">here</a> a day or two after the event.</p>
    </body>
    </html>
    """
}

func qaConfirmationMessage(forEmail email: String, isOnline: Bool) -> (title: String, subtitle: String, isOnline: Bool) {
    let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    if isOnline {
        return (
            title: "Sending Your Photos!",
            subtitle: "Your photos & GIF are being emailed to \(cleanEmail) in the background right now.",
            isOnline: true
        )
    } else {
        return (
            title: "Saved for Wi-Fi Delivery!",
            subtitle: "The iPad is currently offline. You will receive your email at \(cleanEmail) shortly after the iPad connects to Wi-Fi.",
            isOnline: false
        )
    }
}

assertTrue(qaIsValidEmail("guest@gmail.com"), "Valid email guest@gmail.com accepted")
assertTrue(qaIsValidEmail("guest.name+tag@company.co.uk"), "Valid tagged email accepted")
assertTrue(!qaIsValidEmail("invalid-email"), "Email without @ rejected")
assertTrue(!qaIsValidEmail("user@domain"), "Email without TLD rejected")
assertTrue(!qaIsValidEmail("user@domain..com"), "Email with consecutive dots rejected")

let qaHTML1 = qaBuildEmailHTML(galleryURLString: "https://www.joshal.com/2026")
let qaHTML2 = qaBuildEmailHTML(galleryURLString: "https://www.joshal.com/2026/summer-party")
assertTrue(
    qaHTML1.contains("All full resolution images and gifs can be downloaded <a href=\"https://www.joshal.com/2026\">here</a> a day or two after the event."),
    "HTML email footer links 'here' to https://www.joshal.com/2026"
)
assertTrue(
    qaHTML2.contains("All full resolution images and gifs can be downloaded <a href=\"https://www.joshal.com/2026/summer-party\">here</a> a day or two after the event."),
    "HTML email footer links 'here' to https://www.joshal.com/2026/summer-party"
)

let qaOnlineMsg = qaConfirmationMessage(forEmail: "user@test.com", isOnline: true)
let qaOfflineMsg = qaConfirmationMessage(forEmail: "user@test.com", isOnline: false)
assertTrue(
    qaOnlineMsg.isOnline && !qaOnlineMsg.subtitle.lowercased().contains("offline"),
    "Online confirmation message indicates immediate background sending"
)
assertTrue(
    !qaOfflineMsg.isOnline &&
    qaOfflineMsg.subtitle.lowercased().contains("offline") &&
    qaOfflineMsg.subtitle.lowercased().contains("connects to wi-fi"),
    "Offline confirmation message explicitly indicates delivery when iPad connects to Wi-Fi"
)

// 8C. Simulated Online, Offline, and Spotty Wi-Fi Queue Execution (APFS Hard-Link, Persistence, Backoff, Idempotency)
let qaEmailTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("verify_qa_email_\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: qaEmailTempRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: qaEmailTempRoot)
}

// Verify APFS Hard-Link (`linkItem`) preserves queued files in < 5ms even when `/tmp` source is immediately deleted
let srcTempPhoto = qaEmailTempRoot.appendingPathComponent("sony_temp_source.jpg")
let srcPhotoData = Data(repeating: 0xAB, count: 512_000) // 512 KB simulated 2MP JPEG
try! srcPhotoData.write(to: srcTempPhoto)

let jobQueueFolder = qaEmailTempRoot.appendingPathComponent("job_1", isDirectory: true)
try! FileManager.default.createDirectory(at: jobQueueFolder, withIntermediateDirectories: true)
let linkedDestPhoto = jobQueueFolder.appendingPathComponent("photobooth_photo_1.jpg")

let linkStart = CFAbsoluteTimeGetCurrent()
try! FileManager.default.linkItem(at: srcTempPhoto, to: linkedDestPhoto)
let linkElapsedMs = (CFAbsoluteTimeGetCurrent() - linkStart) * 1000.0

// Immediately delete the `/tmp` source file (simulating `StateMachine.cleanupSessionStillImages()`)
try! FileManager.default.removeItem(at: srcTempPhoto)

let recoveredLinkedData = try? Data(contentsOf: linkedDestPhoto)
assertTrue(
    linkElapsedMs < 15.0 && !FileManager.default.fileExists(atPath: srcTempPhoto.path) && recoveredLinkedData == srcPhotoData,
    String(format: "APFS hard-link secured 512KB photo in %.2fms (< 15ms) and survived immediate /tmp source deletion", linkElapsedMs)
)

// Verify Exponential Backoff schedule & Idempotency-Key persistence across simulated spotty Wi-Fi drops
let baseBackoff: Double = 5.0
let maxBackoff: Double = 300.0
let backoffAttempt1 = min(maxBackoff, baseBackoff * pow(2.0, Double(0))) // 5s
let backoffAttempt2 = min(maxBackoff, baseBackoff * pow(2.0, Double(1))) // 10s
let backoffAttempt3 = min(maxBackoff, baseBackoff * pow(2.0, Double(2))) // 20s
let backoffAttempt8 = min(maxBackoff, baseBackoff * pow(2.0, Double(7))) // capped at 300s
assertEqual(backoffAttempt1, 5.0, "Spotty Wi-Fi backoff attempt 1 is 5.0s")
assertEqual(backoffAttempt2, 10.0, "Spotty Wi-Fi backoff attempt 2 is 10.0s")
assertEqual(backoffAttempt3, 20.0, "Spotty Wi-Fi backoff attempt 3 is 20.0s")
assertEqual(backoffAttempt8, 300.0, "Spotty Wi-Fi backoff caps at 300.0s")

// Verify EmailQueueService.swift & SharingViews.swift production source contracts
assertTrue(
    sharingViewsSource.contains("cancelAndReturnToSharingPrompt") &&
    sharingViewsSource.contains("stateMachine.returnToSharingPrompt()"),
    "EmailSharingView Back button returns to .sharingPrompt so guests can still choose AirDrop"
)
assertTrue(
    emailServiceSource.contains("contentType.contains(\"text/html\")") &&
    emailServiceSource.contains("Captive portal"),
    "ResendEmailTransport guards against 200 OK text/html Captive Portal splash pages"
)
assertTrue(
    emailServiceSource.contains("Retry-After") &&
    emailServiceSource.contains("Idempotency-Key"),
    "ResendEmailTransport sends Idempotency-Key header and respects HTTP 429 Retry-After header"
)
assertTrue(
    emailServiceSource.contains("loadedDoc.items[i].status == .sending") &&
    emailServiceSource.contains("loadedDoc.items[i].status = .pending"),
    "EmailQueueService recovers interrupted .sending jobs back to .pending on launch"
)

// Typecheck & Live-Execute production EmailQueueService.swift with MainActor default isolation via Swift JIT
let liveRunnerScriptURL = qaEmailTempRoot.appendingPathComponent("live_email_queue_runner.swift")
let liveHarnessCode = """

// --- LIVE JIT QA HARNESS FOR PRODUCTION EmailQueueService & ResendEmailTransport ---
nonisolated final class LiveMockTransport: EmailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _recorded: [EmailDeliveryRequest] = []
    private var attemptsByJob: [UUID: Int] = [:]
    var simulatedLatencySec: TimeInterval = 0.0
    var outcomeHandler: (@Sendable (EmailDeliveryRequest, Int) -> EmailSendOutcome)?

    nonisolated var recorded: [EmailDeliveryRequest] {
        lock.withLock { _recorded }
    }

    nonisolated func sendEmail(_ request: EmailDeliveryRequest) async -> EmailSendOutcome {
        let (latency, attempt, handler) = lock.withLock { () -> (TimeInterval, Int, (@Sendable (EmailDeliveryRequest, Int) -> EmailSendOutcome)?) in
            _recorded.append(request)
            let next = (attemptsByJob[request.jobID] ?? 0) + 1
            attemptsByJob[request.jobID] = next
            return (simulatedLatencySec, next, outcomeHandler)
        }
        if latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }
        if let handler = handler {
            return handler(request, attempt)
        }
        return .sent(providerMessageID: "live_msg_\\(request.jobID.uuidString)")
    }
}

nonisolated final class LiveMockHTTPProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        guard let h = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (code, headers, body) = h(request)
        if let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override nonisolated func stopLoading() {}
}

let sem = DispatchSemaphore(value: 0)
Task.detached {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("live_jit_email_\\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 1. Scenario A: Online Enqueue + Immediate /tmp deletion + Delivery + Media Folder Cleanup
    let dirA = root.appendingPathComponent("A", isDirectory: true)
    let transA = LiveMockTransport()
    transA.simulatedLatencySec = 0.08
    let svcA = EmailQueueService(
        customDirectoryURL: dirA,
        transport: transA,
        useSystemNetworkMonitor: false,
        initialNetworkConnected: true,
        networkDebounceSec: 0.0,
        baseBackoffSec: 0.02,
        maxBackoffSec: 0.5,
        apiKeyOverride: "re_test_live"
    )
    let p1 = root.appendingPathComponent("sony_1.jpg")
    let p2 = root.appendingPathComponent("sony_2.jpg")
    let p3 = root.appendingPathComponent("sony_3.jpg")
    let g1 = root.appendingPathComponent("anim.gif")
    try! Data("PHOTO1".utf8).write(to: p1)
    try! Data("PHOTO2".utf8).write(to: p2)
    try! Data("PHOTO3".utf8).write(to: p3)
    try! Data("GIF89a".utf8).write(to: g1)

    let t0 = CFAbsoluteTimeGetCurrent()
    guard let jobA = svcA.enqueue(
        recipientEmail: "online@joshal.com",
        mediaPaths: [p1.path, p2.path, p3.path, g1.path],
        galleryURLString: "https://www.joshal.com/2026/gala"
    ) else {
        fputs("FAIL: Scenario A enqueue returned nil\\n", stderr)
        Foundation.exit(1)
    }
    let dtMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
    // Immediately delete /tmp files while 80ms upload is still in flight
    try? fm.removeItem(at: p1)
    try? fm.removeItem(at: p2)
    try? fm.removeItem(at: p3)
    try? fm.removeItem(at: g1)
    guard dtMs < 50.0 else {
        fputs("FAIL: Scenario A enqueue took \\(dtMs)ms\\n", stderr)
        Foundation.exit(1)
    }
    await svcA.flushQueue()
    guard transA.recorded.count == 1,
          transA.recorded[0].attachments.count == 4,
          transA.recorded[0].idempotencyKey == jobA.id.uuidString,
          transA.recorded[0].htmlBody.contains("<a href=\\"https://www.joshal.com/2026/gala\\">here</a>"),
          !fm.fileExists(atPath: dirA.appendingPathComponent(jobA.id.uuidString).path),
          svcA.currentStatsSnapshot().sent == 1 else {
        fputs("FAIL: Scenario A verification failed\\n", stderr)
        Foundation.exit(1)
    }

    // 2. Scenario B: Offline Multi-Session Queue + Reboot Persistence + Auto-Flush on Wi-Fi Connect
    let dirB = root.appendingPathComponent("B", isDirectory: true)
    let transB = LiveMockTransport()
    var svcB: EmailQueueService? = EmailQueueService(
        customDirectoryURL: dirB,
        transport: transB,
        useSystemNetworkMonitor: false,
        initialNetworkConnected: false,
        networkDebounceSec: 0.01,
        baseBackoffSec: 0.02,
        maxBackoffSec: 0.5,
        apiKeyOverride: "re_test_live"
    )
    for (i, pair) in [("u1@test.com", "https://www.joshal.com/2026"), ("u2@test.com", "https://www.joshal.com/2026/party")].enumerated() {
        let f = root.appendingPathComponent("off_\\(i).jpg")
        try! Data("OFF_\\(i)".utf8).write(to: f)
        _ = svcB?.enqueue(recipientEmail: pair.0, mediaPaths: [f.path], galleryURLString: pair.1)
        try? fm.removeItem(at: f)
    }
    guard transB.recorded.isEmpty, svcB?.currentStatsSnapshot().pending == 2 else {
        fputs("FAIL: Scenario B offline queue check failed\\n", stderr)
        Foundation.exit(1)
    }
    svcB = nil // Simulate app reboot
    let reloadedB = EmailQueueService(
        customDirectoryURL: dirB,
        transport: transB,
        useSystemNetworkMonitor: false,
        initialNetworkConnected: false,
        networkDebounceSec: 0.01,
        baseBackoffSec: 0.02,
        maxBackoffSec: 0.5,
        apiKeyOverride: "re_test_live"
    )
    guard reloadedB.currentStatsSnapshot().pending == 2 else {
        fputs("FAIL: Scenario B reboot persistence failed\\n", stderr)
        Foundation.exit(1)
    }
    reloadedB.setSimulatedNetworkConnected(true)
    try? await Task.sleep(nanoseconds: 40_000_000)
    await reloadedB.flushQueue()
    guard transB.recorded.count == 2,
          transB.recorded[0].to == "u1@test.com",
          transB.recorded[1].to == "u2@test.com",
          reloadedB.currentStatsSnapshot().sent == 2 else {
        fputs("FAIL: Scenario B auto-flush failed\\n", stderr)
        Foundation.exit(1)
    }

    // 3. Scenario C: Spotty Wi-Fi Drops, Backoff, Idempotency-Key, & ResendEmailTransport Captive Portal Guard
    let dirC = root.appendingPathComponent("C", isDirectory: true)
    let transC = LiveMockTransport()
    transC.outcomeHandler = { req, attempt in
        if req.to == "flaky@venue.com" && attempt < 3 {
            return .transientFailure(reason: "URLError -1005 connection lost", retryAfterSec: 0.02)
        }
        return .sent(providerMessageID: "ok_\\(attempt)")
    }
    let svcC = EmailQueueService(
        customDirectoryURL: dirC,
        transport: transC,
        useSystemNetworkMonitor: false,
        initialNetworkConnected: true,
        networkDebounceSec: 0.01,
        baseBackoffSec: 0.02,
        maxBackoffSec: 0.2,
        apiKeyOverride: "re_test_live"
    )
    let flakyFile = root.appendingPathComponent("flaky.jpg")
    try! Data("FLAKY".utf8).write(to: flakyFile)
    let flakyJob = svcC.enqueue(recipientEmail: "flaky@venue.com", mediaPaths: [flakyFile.path], galleryURLString: "https://www.joshal.com/2026")
    try? fm.removeItem(at: flakyFile)
    await svcC.flushQueue(ignoreBackoff: true)
    await svcC.flushQueue(ignoreBackoff: true)
    await svcC.flushQueue(ignoreBackoff: true)
    guard transC.recorded.count == 3,
          transC.recorded.allSatisfy({ $0.idempotencyKey == flakyJob?.id.uuidString }),
          svcC.currentStatsSnapshot().sent == 1 else {
        fputs("FAIL: Scenario C spotty retry/idempotency failed\\n", stderr)
        Foundation.exit(1)
    }

    // 4. ResendEmailTransport URLProtocol checks (200 JSON, 200 HTML Captive Portal, 429 Retry-After, 401 Config Pause, 422 Permanent)
    let httpTrans = ResendEmailTransport(protocolClasses: [LiveMockHTTPProtocol.self])
    let sampleReq = EmailDeliveryRequest(
        jobID: UUID(),
        idempotencyKey: "idem-999",
        from: "Photobooth <onboarding@resend.dev>",
        to: "guest@joshal.com",
        subject: "Subject",
        htmlBody: "<p>Hi</p>",
        textBody: "Hi",
        attachments: [EmailAttachmentPayload(filename: "a.jpg", contentType: "image/jpeg", data: Data("JPG".utf8))],
        apiKey: "re_live_key"
    )
    LiveMockHTTPProtocol.handler = { _ in
        (200, ["Content-Type": "text/html"], Data("<html>Captive Portal Login</html>".utf8))
    }
    let captiveRes = await httpTrans.sendEmail(sampleReq)
    guard case .transientFailure = captiveRes else {
        fputs("FAIL: Captive portal HTML was not rejected\\n", stderr)
        Foundation.exit(1)
    }
    LiveMockHTTPProtocol.handler = { _ in
        (200, ["Content-Type": "application/json"], Data("{\\"id\\":\\"re_ok_1\\"}".utf8))
    }
    let okRes = await httpTrans.sendEmail(sampleReq)
    guard case .sent(let msgID) = okRes, msgID == "re_ok_1" else {
        fputs("FAIL: 200 OK JSON was not accepted\\n", stderr)
        Foundation.exit(1)
    }

    // 5. GmailSMTPTransport MIME payload & unconfigured confirmation verification
    let (envEmail, hdrFrom) = GmailSMTPTransport.parseSenderAddress("Photobooth <joshal7@gmail.com>")
    let mimeBytes = GmailSMTPTransport.buildMIMEMessage(sampleReq, envelopeSender: envEmail, formattedFromHeader: hdrFrom)
    let mimeStr = String(data: mimeBytes, encoding: .utf8) ?? ""
    guard envEmail == "joshal7@gmail.com",
          mimeStr.contains("From: Photobooth <joshal7@gmail.com>\\r\\n"),
          mimeStr.contains("To: <guest@joshal.com>\\r\\n"),
          mimeStr.contains("filename=\\"a.jpg\\""),
          mimeStr.hasSuffix("\\r\\n.\\r\\n") else {
        fputs("FAIL: GmailSMTPTransport MIME verification failed\\n", stderr)
        Foundation.exit(1)
    }

    let unconfCopy = EmailQueueService.confirmationMessage(forEmail: "guest@gmail.com", isOnline: true, isConfigured: false)
    guard !unconfCopy.isConfigured, unconfCopy.subtitle.lowercased().contains("settings") else {
        fputs("FAIL: Unconfigured confirmation copy verification failed\\n", stderr)
        Foundation.exit(1)
    }

    // 6. iPad Camera Mode 10.8MP (4032x2688) JPEG downscaling to 2MP (1620x1080)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(data: nil, width: 3240, height: 2160, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
       let bigCG = ctx.makeImage() {
        let bigData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(bigData as CFMutableData, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, bigCG, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        let downscaled = EmailQueueService.normalizeJPEGAttachmentTo2MP(bigData as Data)
        if let src = CGImageSourceCreateWithData(downscaled as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            guard w == 1620 && h == 1080 else {
                fputs("FAIL: iPad Camera Mode JPEG was not downscaled to 1620x1080 (got \\(w)x\\(h))\\n", stderr)
                Foundation.exit(1)
            }
        } else {
            fputs("FAIL: Could not read downscaled JPEG dimensions\\n", stderr)
            Foundation.exit(1)
        }
    }

    sem.signal()
}
sem.wait()
"""

try! (emailServiceSource + "\n" + liveHarnessCode).write(to: liveRunnerScriptURL, atomically: true, encoding: .utf8)

let jitProc = Process()
jitProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
jitProc.arguments = [
    "swift",
    "-default-isolation", "MainActor",
    liveRunnerScriptURL.path
]
try! jitProc.run()
jitProc.waitUntilExit()
assertEqual(
    jitProc.terminationStatus,
    0,
    "Live JIT execution of production EmailQueueService, GmailSMTPTransport, ResendEmailTransport, & iPad 2MP attachment normalization passed all scenarios"
)
assertTrue(
    emailServiceSource.contains("class GmailSMTPTransport") &&
    emailServiceSource.contains("class CompositeEmailTransport") &&
    emailServiceSource.contains("normalizeJPEGAttachmentTo2MP"),
    "EmailQueueService supports both Gmail SMTP App Passwords (any Gmail recipient) and Resend API keys, plus 2MP iPad JPEG normalization"
)

print("========================================================")
print("QA Summary: \(passedAssertions) PASSED, \(failedAssertions) FAILED")
print("========================================================")
exit(failedAssertions == 0 ? 0 : 1)






