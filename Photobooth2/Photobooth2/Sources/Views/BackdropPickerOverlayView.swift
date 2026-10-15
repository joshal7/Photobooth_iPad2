import SwiftUI

struct BackdropPickerOverlayView: View {
    @EnvironmentObject var stateMachine: StateMachine
    @ObservedObject var backdropManager: BackdropManager = .shared
    
    /// Generous invisible touch-absorbing buffer padding around the pill and carousel
    /// so stray taps near the bottom of the screen never accidentally trigger "Take 3 Photos".
    static let shieldHorizontalMargin: CGFloat = 48
    static let shieldTopMargin: CGFloat = 32
    static let collapsedShieldSize = CGSize(width: 420, height: 110)
    static let expandedShieldHeight: CGFloat = 250
    
    /// Deterministic geometry check verifying whether a tap point in `screenSize` falls inside the
    /// bottom touch-absorbing shield (preventing accidental capture triggers).
    static func isPointInsideShield(_ point: CGPoint, screenSize: CGSize, isExpanded: Bool) -> Bool {
        guard screenSize.width > 0, screenSize.height > 0 else { return false }
        if isExpanded {
            let shieldWidth = min(screenSize.width, max(640, screenSize.width - 80))
            let minX = (screenSize.width - shieldWidth) * 0.5
            let maxX = minX + shieldWidth
            let minY = screenSize.height - expandedShieldHeight
            return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= screenSize.height
        } else {
            let shieldWidth = min(screenSize.width, collapsedShieldSize.width)
            let minX = (screenSize.width - shieldWidth) * 0.5
            let maxX = minX + shieldWidth
            let minY = screenSize.height - collapsedShieldSize.height
            return point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= screenSize.height
        }
    }
    
    var body: some View {
        // Only show the picker if there is at least one non-Original backdrop available,
        // or always show if enabledBackdrops.count > 1
        let items = backdropManager.enabledBackdrops
        if items.count > 1 {
            VStack {
                Spacer()
                
                ZStack(alignment: .bottom) {
                    // Touch-absorbing shield zone: absorbs slightly off-target taps around the pill/carousel
                    // so they never pass through to the "Take 3 Photos" button underneath.
                    // When the carousel is expanded, tapping in the outer margin collapses it cleanly.
                    Color.white.opacity(0.001)
                        .frame(
                            maxWidth: stateMachine.isBackdropPickerExpanded ? .infinity : Self.collapsedShieldSize.width,
                            maxHeight: stateMachine.isBackdropPickerExpanded ? Self.expandedShieldHeight : Self.collapsedShieldSize.height
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if stateMachine.isBackdropPickerExpanded {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    stateMachine.isBackdropPickerExpanded = false
                                }
                            }
                        }
                    
                    if stateMachine.isBackdropPickerExpanded {
                        expandedCarouselView(items: items)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        collapsedPillView()
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
            }
            .edgesIgnoringSafeArea(.bottom)
        }
    }
    
    @ViewBuilder
    private func collapsedPillView() -> some View {
        HStack(spacing: 10) {
            Button(action: {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                    stateMachine.isBackdropPickerExpanded = true
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: stateMachine.selectedBackdrop.isNone ? "sparkles" : "wand.and.stars")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(stateMachine.selectedBackdrop.isNone ? .white.opacity(0.9) : .cyan)
                    
                    Text(stateMachine.selectedBackdrop.isNone
                         ? "Backgrounds & Frames"
                         : "Backdrop: \(stateMachine.selectedBackdrop.displayName)")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            
            if !stateMachine.selectedBackdrop.isNone {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        stateMachine.selectBackdrop(.none)
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .padding(.trailing, 14)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            ZStack {
                Capsule()
                    .fill(.ultraThinMaterial)
                Capsule()
                    .fill(Color.black.opacity(0.50))
            }
        )
        .overlay(
            Capsule()
                .stroke(
                    stateMachine.selectedBackdrop.isNone
                        ? Color.white.opacity(0.24)
                        : Color.cyan.opacity(0.65),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 4)
        .padding(.bottom, 22)
    }
    
    @ViewBuilder
    private func expandedCarouselView(items: [BackdropItem]) -> some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.cyan)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Select Background or Frame")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        stateMachine.isBackdropPickerExpanded = false
                    }
                }) {
                    HStack(spacing: 5) {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        backdropThumbnailCard(for: item)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: 820)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.62))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 18, x: 0, y: 6)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
    
    @ViewBuilder
    private func backdropThumbnailCard(for item: BackdropItem) -> some View {
        let isSelected = (stateMachine.selectedBackdrop.id == item.id)
        
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                stateMachine.selectBackdrop(item)
            }
        }) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    if item.isNone {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                            VStack(spacing: 4) {
                                Image(systemName: "person.crop.rectangle")
                                    .font(.system(size: 26, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                Text("Live Room")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.65))
                            }
                        }
                        .frame(width: 120, height: 80)
                    } else if let thumb = backdropManager.thumbnail(for: item) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .frame(width: 120, height: 80)
                    }
                    
                    if !item.isNone {
                        Text(badgeLabel(for: item))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.68)))
                            .padding(5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.cyan : Color.white.opacity(0.20), lineWidth: isSelected ? 3.0 : 1.0)
                )
                
                Text(item.displayName)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .cyan : .white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 120)
            }
        }
        .buttonStyle(.plain)
    }
    
    private func badgeLabel(for item: BackdropItem) -> String {
        if item.isCombo {
            return "COMBO"
        } else if item.hasForeground {
            return "FRAME"
        } else {
            return "BG"
        }
    }
}

