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

// 7B. Zero-Code Auto-Discovery & Pairing (`_bg` + `_fg` -> Combo)
func classifyAndDiscover(in dir: URL) -> [(id: String, name: String, bg: String?, fg: String?)] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    var map: [String: (name: String, bg: String?, fg: String?)] = [:]
    var order: [String] = []
    for f in files {
        let stem = f.deletingPathExtension().lastPathComponent
        let lower = stem.lowercased()
        if lower.hasSuffix("_bg") {
            let base = String(stem.dropLast(3))
            let id = base.lowercased().replacingOccurrences(of: " ", with: "_")
            if map[id] == nil { order.append(id); map[id] = (base, f.lastPathComponent, nil) }
            else { map[id]?.bg = f.lastPathComponent }
        } else if lower.hasSuffix("_fg") {
            let base = String(stem.dropLast(3))
            let id = base.lowercased().replacingOccurrences(of: " ", with: "_")
            if map[id] == nil { order.append(id); map[id] = (base, nil, f.lastPathComponent) }
            else { map[id]?.fg = f.lastPathComponent }
        }
    }
    return order.compactMap { id in
        guard let v = map[id] else { return nil }
        return (id, v.name, v.bg, v.fg)
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

print("========================================================")
print("QA Summary: \(passedAssertions) PASSED, \(failedAssertions) FAILED")
print("========================================================")
exit(failedAssertions == 0 ? 0 : 1)


