import SwiftUI

struct LookAtCameraView: View {
    let useLocalCamera: Bool
    @State private var orientation: UIDeviceOrientation = UIDevice.current.orientation
    
    var body: some View {
        ZStack {
            // 1. Centered Text
            textLabel
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(20)
            
            // 2. Arrow positioned at the edge
            arrowContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Ignore safe area to get arrow close to the bezel/camera
        .edgesIgnoringSafeArea(.all)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            self.orientation = UIDevice.current.orientation
        }
    }
    
    var arrowContainer: some View {
        VStack {
            if arrowDirection == .down {
                Spacer()
                arrowImage.padding(.bottom, 50) // Within an inch (~50-70pts)
            } else if arrowDirection == .up {
                arrowImage.padding(.top, 50)
                Spacer()
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(
            HStack {
                if arrowDirection == .right {
                    Spacer()
                    arrowImage.padding(.trailing, 50)
                } else if arrowDirection == .left {
                    arrowImage.padding(.leading, 50)
                    Spacer()
                }
            }
        )
    }
    
    var textLabel: some View {
        Text("Look at the camera,\nnot the screen")
            .font(.system(size: 60, weight: .bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
    }
    
    var arrowImage: some View {
        Image(systemName: arrowIconName)
            .font(.system(size: 100, weight: .bold))
            .foregroundColor(.yellow)
            .shadow(color: .black, radius: 2, x: 0, y: 0)
    }
    
    enum ArrowDirection {
        case up, down, left, right
    }
    
    var arrowDirection: ArrowDirection {
        if !useLocalCamera {
            return .up // External camera is always "up" (above screen usually)
        }
        
        // iPad Camera Logic (Front camera is on the top bezel in Portrait)
        switch orientation {
        case .portrait:
            return .up
        case .portraitUpsideDown:
            return .down
        case .landscapeLeft: // Home button right -> Camera is left
            return .left
        case .landscapeRight: // Home button left -> Camera is right
            return .right
        default:
            return .up
        }
    }
    
    var arrowIconName: String {
        switch arrowDirection {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}
