@preconcurrency import AVFoundation
import ScreenCapCore

/// The raw tracks laid out on the output timeline (cuts and trims applied by reference;
/// the media files themselves are never touched).
struct BuiltComposition {
    let asset: AVMutableComposition
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?
    let micTrack: CMPersistentTrackID?
    let systemTrack: CMPersistentTrackID?
}

/// The one place a composition is assembled, used by both the editor preview and the exporter.
@MainActor
enum CompositionBuilder {
    static func build(bundle: ReelBundle, timeline: Timeline) async throws -> BuiltComposition {
        let composition = AVMutableComposition()

        func add(_ url: URL, _ type: AVMediaType) async throws -> CMPersistentTrackID? {
            guard bundle.has(url) else { return nil }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: type).first else { return nil }
            let available = try await track.load(.timeRange)
            guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }
            var offset = 0.0
            for segment in timeline.segments {
                let wanted = CMTimeRange(start: time(segment.start), end: time(segment.end))
                // A track can start late or end early (the camera warming up, say); leave a gap there.
                let range = wanted.intersection(available)
                if range.duration > .zero {
                    try target.insertTimeRange(range, of: track, at: time(offset) + (range.start - wanted.start))
                }
                offset += segment.duration
            }
            return target.trackID
        }

        guard let screen = try await add(bundle.screen, .video) else {
            throw RecordingError.writerSetup("the screen track is missing or unreadable")
        }
        return BuiltComposition(
            asset: composition, screenTrack: screen,
            cameraTrack: try await add(bundle.camera, .video),
            micTrack: try await add(bundle.mic, .audio),
            systemTrack: try await add(bundle.systemAudio, .audio))
    }

    static func videoComposition(for built: BuiltComposition, state: RenderState, canvas: CGSize, fps: Int) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = Compositor.self
        composition.renderSize = canvas
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [
            ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: built.asset.duration), state: state),
        ]
        return composition
    }

    static func audioMix(for built: BuiltComposition, volumes: Volumes) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = [(built.micTrack, volumes.mic), (built.systemTrack, volumes.system)].compactMap { id, volume in
            guard let id, let track = built.asset.track(withTrackID: id) else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(volume), at: .zero)
            return parameters
        }
        return mix
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}
