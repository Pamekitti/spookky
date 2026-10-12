import AppKit
import IOSurface

enum RenderedFixtureProbe {
    static func matches(_ view: TerminalHostView, green: Bool) -> Bool {
        guard let contents = view.layer?.contents else { return false }
        let object = contents as AnyObject
        guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { return false }
        let image = unsafeBitCast(object, to: IOSurfaceRef.self)
        guard IOSurfaceGetBytesPerElement(image) == 4,
              IOSurfaceLock(image, .readOnly, nil) == 0 else { return false }
        defer { IOSurfaceUnlock(image, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(image)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let width = min(IOSurfaceGetWidth(image), 600)
        let height = min(IOSurfaceGetHeight(image), 150)
        let stride = IOSurfaceGetBytesPerRow(image)
        for y in Swift.stride(from: 0, to: height, by: 8) {
            for x in Swift.stride(from: 0, to: width, by: 8) {
                let offset = y * stride + x * 4
                let b = bytes[offset], g = bytes[offset + 1], r = bytes[offset + 2]
                if b < 150 && (green ? (g > 200 && r < 150) : (r > 200 && g < 150)) { return true }
            }
        }
        return false
    }
}
