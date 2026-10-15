import SwiftUI

/// A rounded-rectangle perimeter shape whose path begins and ends at exact 12 o'clock (Top-Center)
/// and traces clockwise (12 -> 3 -> 6 -> 9 -> 12 o'clock) on any rectangular screen aspect ratio.
struct TopCenterPerimeterRoundedRect: Shape {
    var cornerRadius: CGFloat = 28
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        
        let r = min(cornerRadius, min(rect.width, rect.height) * 0.5)
        let topCenter = CGPoint(x: rect.midX, y: rect.minY)
        
        path.move(to: topCenter)
        // Top-Center -> Top-Right corner
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        // Right edge -> Bottom-Right corner
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom edge -> Bottom-Left corner
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        // Left edge -> Top-Left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        // Top-Left -> back to Top-Center (12 o'clock)
        path.addLine(to: topCenter)
        
        return path
    }
}

/// Crisp 0.2s perimeter vignette flash that expands directly from the 22pt perimeter trace
/// when each GIF frame is captured, giving clear shutter feedback without blinding the center Live View.
struct GIFVignetteFlashOverlay: View {
    private let flashBorderWidth: CGFloat = 54
    private let cornerRadius: CGFloat = 28
    
    var body: some View {
        ZStack {
            // Subtle warm-white ambient wash so the shutter pulse is felt across the frame
            Color.white.opacity(0.14)
            
            // High-intensity feathered perimeter border flash
            TopCenterPerimeterRoundedRect(cornerRadius: cornerRadius)
                .inset(by: flashBorderWidth * 0.5)
                .stroke(Color.white, lineWidth: flashBorderWidth)
                .shadow(color: Color.white, radius: 28)
                .shadow(color: Color.white.opacity(0.85), radius: 55)
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
}

/// Animatable left-to-right wait bar fill rendered inside the Top-Center pill capsule background in GIF mode.
/// Fills from left (10% trailing white opacity) to right (30% leading white opacity), completing just before the flash.
struct PillWaitBarFill: View, Animatable {
    var progress: CGFloat
    
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    
    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0.0), 1.0)
            if clamped > 0.001 {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.white.opacity(0.10), location: 0.0),
                        .init(color: Color.white.opacity(0.20), location: 0.60),
                        .init(color: Color.white.opacity(0.30), location: 1.0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * clamped, height: geo.size.height)
            }
        }
    }
}

/// Sleek Top-Center progress dot pill shared by GIF mode and Photo mode.
/// - Completed frames (`index < activeFrameIndex`): solid white filled circle (20pt)
/// - Current frame (`index == activeFrameIndex`, about to be taken): 1.5x size (30pt) with pulsing white center
/// - Future frames (`index > activeFrameIndex`): hollow white circle (20pt)
/// - In GIF mode, `waitProgress` (0.0 -> 1.0) fills the pill's glassy black background from left to right
///   with a 10% trailing -> 30% leading white gradient just before the next flash.
struct GIFProgressDotsPillView: View {
    let totalFrames: Int
    let activeFrameIndex: Int
    var waitProgress: CGFloat = 0.0
    
    @State private var isPulsing: Bool = false
    
    private let baseDotSize: CGFloat = 20
    private let activeDotSize: CGFloat = 30 // 1.5x baseDotSize
    
    var body: some View {
        HStack(spacing: 18) {
            ForEach(1...max(1, totalFrames), id: \.self) { index in
                dotView(for: index)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(
            ZStack(alignment: .leading) {
                Color.black.opacity(0.48)
                PillWaitBarFill(progress: waitProgress)
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.20), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
    
    @ViewBuilder
    private func dotView(for index: Int) -> some View {
        if index < activeFrameIndex {
            // Completed: solid white filled
            Circle()
                .fill(Color.white)
                .frame(width: baseDotSize, height: baseDotSize)
                .shadow(color: Color.white.opacity(0.5), radius: 4)
                .transition(.scale)
        } else if index == activeFrameIndex {
            // Current (about to be taken): 1.5x size with outer white ring + pulsing white center core
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 3.0)
                    .frame(width: activeDotSize, height: activeDotSize)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: activeDotSize * 0.56, height: activeDotSize * 0.56)
                    .scaleEffect(isPulsing ? 1.08 : 0.72)
                    .opacity(isPulsing ? 1.0 : 0.65)
                    .shadow(color: Color.white.opacity(0.9), radius: 6)
            }
            .frame(width: activeDotSize, height: activeDotSize)
        } else {
            // Future: white hollow circle
            Circle()
                .stroke(Color.white.opacity(0.50), lineWidth: 2.5)
                .frame(width: baseDotSize, height: baseDotSize)
        }
    }
}

extension TopCenterPerimeterRoundedRect: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape {
        InsetTopCenterPerimeterRoundedRect(cornerRadius: max(0, cornerRadius - amount * 0.5), insetAmount: amount)
    }
}

private struct InsetTopCenterPerimeterRoundedRect: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat
    
    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return TopCenterPerimeterRoundedRect(cornerRadius: cornerRadius).path(in: insetRect)
    }
    
    func inset(by amount: CGFloat) -> some InsettableShape {
        InsetTopCenterPerimeterRoundedRect(
            cornerRadius: max(0, cornerRadius - amount * 0.5),
            insetAmount: insetAmount + amount
        )
    }
}
