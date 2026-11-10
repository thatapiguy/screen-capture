@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenCapCore

/// Everything needed to draw any frame, frozen at the moment of an edit. The editor builds a
/// new one for each change and the exporter builds one for the export, so preview and export
/// go through exactly the same drawing code.
final class RenderState: @unchecked Sendable {
    let timeline: Timeline
    let edits: EditDecisions
    let info: ProjectInfo
    let zoomPath: ZoomPath
    /// Cursor path with the user's smoothing already applied.
    let cursor: CursorTrack
    let cursorImage: CIImage?
    /// Cursor image size and hot spot, in screen points.
    let cursorSize: CGSize
    let cursorHotSpot: CGPoint
    /// Editor only: draw unzoomed so the framing rectangle of the selected zoom makes sense.
    let showsFullFrame: Bool
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?

    init(timeline: Timeline, edits: EditDecisions, info: ProjectInfo, zoomPath: ZoomPath, cursor: CursorTrack,
         cursorImage: CIImage?, cursorSize: CGSize, cursorHotSpot: CGPoint, showsFullFrame: Bool,
         screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?) {
        self.timeline = timeline
        self.edits = edits
        self.info = info
        self.zoomPath = zoomPath
        self.cursor = cursor
        self.cursorImage = cursorImage
        self.cursorSize = cursorSize
        self.cursorHotSpot = cursorHotSpot
        self.showsFullFrame = showsFullFrame
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
    }
}

/// A single instruction spans the whole composition; all per-frame variation comes from RenderState.
final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let state: RenderState

    init(timeRange: CMTimeRange, state: RenderState) {
        self.timeRange = timeRange
        self.state = state
        requiredSourceTrackIDs = ([state.screenTrack] + (state.cameraTrack.map { [$0] } ?? []))
            .map { NSNumber(value: $0) }
    }
}

/// Draws one output frame: background, zoomed screen with cursor and click ripples, camera inset.
final class Compositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let pixelFormat = kCVPixelFormatType_32BGRA
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    /// The blurred shadow and gradient never change between frames, so they're rendered once per state.
    private var backdropCache: (state: RenderState, size: CGSize, image: CIImage)?

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat, kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat, kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ReelInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "ScreenCap.Compositor", code: 1))
            return
        }
        let state = instruction.state
        let canvas = request.renderContext.size
        let time = state.timeline.sourceTime(forOutput: request.compositionTime.seconds)

        var frame = backdrop(state: state, canvas: canvas)
        if let buffer = request.sourceFrame(byTrackID: state.screenTrack) {
            frame = screenLayer(CIImage(cvPixelBuffer: buffer), state: state, time: time, canvas: canvas, over: frame)
        }
        if let track = state.cameraTrack, state.edits.camera.enabled,
           !state.edits.cameraHidden.contains(where: { time >= $0.start && time < $0.end }),
           let buffer = request.sourceFrame(byTrackID: track) {
            frame = cameraLayer(CIImage(cvPixelBuffer: buffer), layout: state.edits.camera, canvas: canvas, over: frame)
        }
        context.render(frame, to: output, bounds: CGRect(origin: .zero, size: canvas), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    // MARK: - Layers. Core Image's origin is bottom-left; Layout and cursor data use top-left.

    private func flipped(_ rect: CGRect, in canvas: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func roundedMask(_ rect: CGRect, radius: CGFloat, color: CIColor = .white) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(min(radius, min(rect.width, rect.height) / 2))
        generator.color = color
        return generator.outputImage ?? CIImage.empty()
    }

    private func masked(_ image: CIImage, by mask: CIImage, over background: CIImage) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? image
    }

    private func color(_ hex: UInt32) -> CIColor {
        CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255)
    }

    private func backdrop(state: RenderState, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let background = state.edits.background
        guard background.enabled else { return CIImage(color: .black).cropped(to: bounds) }
        if let cached = lock.withLock({ backdropCache }), cached.state === state, cached.size == canvas { return cached.image }

        let colors = Background.presets[min(max(0, background.preset), Background.presets.count - 1)]
        var image: CIImage
        if colors.count > 1 {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: 0, y: canvas.height)
            gradient.point1 = CGPoint(x: canvas.width, y: 0)
            gradient.color0 = color(colors[0])
            gradient.color1 = color(colors[1])
            image = (gradient.outputImage ?? CIImage(color: color(colors[0]))).cropped(to: bounds)
        } else {
            image = CIImage(color: color(colors[0])).cropped(to: bounds)
        }
        if background.shadow {
            let shortSide = min(canvas.width, canvas.height)
            let frame = flipped(Layout.screenFrame(canvas: canvas, background: background), in: canvas)
            let shadow = roundedMask(frame.offsetBy(dx: 0, dy: -shortSide * 0.012), radius: shortSide * background.cornerRadius,
                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
                .clampedToExtent().applyingGaussianBlur(sigma: shortSide * 0.025).cropped(to: bounds)
            image = shadow.composited(over: image)
        }
        // Flatten to a bitmap so the blur isn't recomputed for every frame.
        if let bitmap = context.createCGImage(image, from: bounds) { image = CIImage(cgImage: bitmap) }
        lock.withLock { backdropCache = (state, canvas, image) }
        return image
    }

    private func screenLayer(_ source: CIImage, state: RenderState, time: Double, canvas: CGSize, over backdrop: CIImage) -> CIImage {
        let size = source.extent.size
        var screen = source
        let style = state.edits.cursor
        // Recorded positions are relative to the capture area in points; the track may be scaled down.
        let pointScale = CGFloat(state.info.scale) * size.width / CGFloat(max(1, state.info.width))

        if style.visible {
            if style.highlightClicks {
                for click in state.cursor.clicks where time >= click.t && time - click.t < 0.45 {
                    let progress = CGFloat((time - click.t) / 0.45)
                    let radius = (10 + 26 * progress) * pointScale * CGFloat(style.scale)
                    let center = CGPoint(x: click.x * size.width, y: (1 - click.y) * size.height)
                    let ripple = CIFilter.radialGradient()
                    ripple.center = center
                    ripple.radius0 = Float(radius * 0.7)
                    ripple.radius1 = Float(radius)
                    ripple.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.45 * (1 - progress))
                    ripple.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
                    if let image = ripple.outputImage {
                        screen = image.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                            .composited(over: screen)
                    }
                }
            }
            if let image = state.cursorImage, let position = state.cursor.position(at: time),
               (-0.05...1.05).contains(position.x), (-0.05...1.05).contains(position.y) {
                let scale = state.cursorSize.width * pointScale * CGFloat(style.scale) / image.extent.width
                let hotSpot = CGPoint(x: state.cursorHotSpot.x * pointScale * CGFloat(style.scale),
                                      y: state.cursorHotSpot.y * pointScale * CGFloat(style.scale))
                let x = position.x * size.width - hotSpot.x
                let top = (1 - position.y) * size.height + hotSpot.y
                screen = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: x, y: top - image.extent.height * scale))
                    .composited(over: screen)
            }
        }

        // Zoom by cropping the full-resolution source and scaling it into the frame, so text stays sharp.
        let zoom = state.showsFullFrame ? (scale: 1.0, center: CGPoint(x: 0.5, y: 0.5)) : state.zoomPath.sample(at: time)
        let visible = Layout.visibleRect(scale: zoom.scale, center: zoom.center)
        let crop = CGRect(x: visible.minX * size.width, y: (1 - visible.maxY) * size.height,
                          width: visible.width * size.width, height: visible.height * size.height)
        let frame = flipped(Layout.screenFrame(canvas: canvas, background: state.edits.background), in: canvas)
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: frame.width / crop.width, y: frame.height / crop.height))
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
        let placed = screen.cropped(to: source.extent).clampedToExtent().transformed(by: transform).cropped(to: frame)

        guard state.edits.background.enabled else { return placed.composited(over: backdrop) }
        let radius = min(canvas.width, canvas.height) * state.edits.background.cornerRadius
        return masked(placed, by: roundedMask(frame, radius: radius), over: backdrop)
    }

    private func cameraLayer(_ source: CIImage, layout: CameraLayout, canvas: CGSize, over background: CIImage) -> CIImage {
        let frame = flipped(Layout.cameraFrame(canvas: canvas, camera: layout), in: canvas)
        let side = min(source.extent.width, source.extent.height)
        let square = CGRect(x: source.extent.midX - side / 2, y: source.extent.midY - side / 2, width: side, height: side)
        let scale = frame.width / side
        var transform = CGAffineTransform(translationX: -square.minX, y: -square.minY)
        if layout.mirrored {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                .concatenating(CGAffineTransform(translationX: side, y: 0))
        }
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
        let placed = source.cropped(to: square).transformed(by: transform).cropped(to: frame)

        let radius = layout.shape == .circle ? frame.width / 2 : frame.width * 0.16
        var result = background
        if layout.border {
            let width = frame.width * 0.02
            let ring = frame.insetBy(dx: -width, dy: -width)
            result = roundedMask(ring, radius: radius + width, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95))
                .composited(over: result)
        }
        return masked(placed, by: roundedMask(frame, radius: radius), over: result)
    }
}
