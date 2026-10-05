import AppKit

/// AppKit uses a bottom-left origin; CoreGraphics events use a top-left origin
/// anchored to the primary display. All gaze points in this app are CoreGraphics coordinates.
@MainActor
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cgRect(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    static func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(matchingCG rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { cgRect(of: $0) == rect }
    }

    static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Points per millimetre, if the display reports its physical size.
    static func pointsPerMillimetre(_ screen: NSScreen) -> Double? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        return mm.width > 0 ? Double(screen.frame.width / mm.width) : nil
    }
}
