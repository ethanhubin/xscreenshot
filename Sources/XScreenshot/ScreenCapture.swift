import AppKit
import ScreenCaptureKit

struct DisplaySnapshot {
    let image: CGImage
    let size: CGSize

    private var pixelScale: CGSize {
        CGSize(width: CGFloat(image.width) / size.width, height: CGFloat(image.height) / size.height)
    }

    func pixelRect(for region: CGRect) -> CGRect {
        let scale = pixelScale
        return region.applying(CGAffineTransform(scaleX: scale.width, y: scale.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    @MainActor
    func export(region: CGRect, markup: [Markup]) throws -> CGImage {
        let pixels = pixelRect(for: region)
        guard !pixels.isEmpty, let cropped = image.cropping(to: pixels) else { throw CaptureError.imageEncodingFailed }
        guard !markup.isEmpty else { return cropped }

        let sourceColorSpace = cropped.colorSpace
        let colorSpace = sourceColorSpace?.model == .rgb ? sourceColorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace, let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.imageEncodingFailed
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        // Both the preview and annotations use display points measured from the top left.
        context.translateBy(x: -pixels.minX, y: CGFloat(cropped.height) + pixels.minY)
        let scale = pixelScale
        context.scaleBy(x: scale.width, y: -scale.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in markup { annotation.draw(in: context) }
        guard let result = context.makeImage() else { throw CaptureError.imageEncodingFailed }
        return result
    }
}

enum ScreenCapture {
    static func snapshots(for sizes: [CGDirectDisplayID: CGSize],
                          includingOwnWindows: Bool) async throws -> [CGDirectDisplayID: DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedApps = includingOwnWindows ? [] : content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        var snapshots: [CGDirectDisplayID: DisplaySnapshot] = [:]
        for display in content.displays {
            guard let size = sizes[display.displayID] else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((size.width * scale).rounded())
            configuration.height = Int((size.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots[display.displayID] = DisplaySnapshot(image: image, size: size)
        }
        guard !snapshots.isEmpty else { throw CaptureError.displayUnavailable }
        return snapshots
    }

    @MainActor
    static func copyToClipboard(_ image: CGImage) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let item = NSPasteboardItem()
        guard let data = bitmap.representation(using: .png, properties: [:]),
              item.setData(data, forType: .png) else {
            throw CaptureError.imageEncodingFailed
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CaptureError.clipboardWriteFailed }
    }
}

private enum CaptureError: LocalizedError {
    case displayUnavailable
    case imageEncodingFailed
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "找不到选区所在的显示器，请重新截图。"
        case .imageEncodingFailed: "无法生成 PNG 图片，请重新截图。"
        case .clipboardWriteFailed: "无法写入剪贴板，请重新截图。"
        }
    }
}
