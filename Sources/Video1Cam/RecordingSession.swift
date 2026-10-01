@preconcurrency import AVFoundation
import CoreMedia
import RecorderCore
import ScreenCaptureKit

struct RecordingConfig {
    var display: SCDisplay
    /// Region in display-local points, top-left origin. nil = whole display.
    var sourceRect: CGRect?
    var video: VideoSettings
    var showClicks: Bool
    var systemAudio: Bool
    var microphone: Bool
    var microphoneID: String?
    var excludedApps: [SCRunningApplication]
    var includedWindows: [SCWindow]
    var rawURL: URL
}

/// Owns the SCStream and feeds the MovieWriter. Sample callbacks, pause/resume and
/// finish all run on `queue`, which is what MovieWriter requires.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "coop.up.video1cam.capture", qos: .userInteractive)
    private var stream: SCStream!
    private let writer: MovieWriter
    private let systemTrack: Int?
    private let micTrack: Int?
    private var stopped = false
    private var failureReported = false
    let rawURL: URL

    private let levelLock = NSLock()
    private var _micPeak: Float = 0

    /// Called on the main queue if the system stops the stream (display unplugged, user stopped sharing…).
    var onUnexpectedStop: ((Error) -> Void)?

    init(config c: RecordingConfig) throws {
        var trackCount = 0
        systemTrack = c.systemAudio ? 0 : nil
        if c.systemAudio { trackCount += 1 }
        micTrack = c.microphone ? trackCount : nil
        if c.microphone { trackCount += 1 }
        writer = try MovieWriter(url: c.rawURL, video: c.video, audioTrackCount: trackCount)
        rawURL = c.rawURL

        let filter = SCContentFilter(display: c.display, excludingApplications: c.excludedApps, exceptingWindows: c.includedWindows)
        let cfg = SCStreamConfiguration()
        cfg.width = c.video.width
        cfg.height = c.video.height
        if let r = c.sourceRect { cfg.sourceRect = r }
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.captureResolution = .best
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(c.video.fps))
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.showMouseClicks = c.showClicks
        cfg.capturesAudio = c.systemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = c.microphone
        if c.microphone, let id = c.microphoneID, !id.isEmpty { cfg.microphoneCaptureDeviceID = id }

        super.init()
        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if c.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if c.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        } catch {
            writer.cancel()
            throw error
        }
    }

    /// True if the stream has ended (stopped by us or by the system).
    var isStopped: Bool { queue.sync { stopped } }

    func start() async throws {
        do {
            try await stream.startCapture()
        } catch {
            queue.sync { writer.cancel() }
            throw error
        }
    }

    static var hostNow: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    func pause() {
        let t = Self.hostNow
        queue.async { self.writer.pause(at: t) }
    }

    func resume() {
        let t = Self.hostNow
        queue.async { self.writer.resume(at: t) }
    }

    /// Current mic peak (0…1), decays between reads.
    var micPeak: Float {
        levelLock.lock(); defer { levelLock.unlock() }
        let v = _micPeak
        _micPeak *= 0.5
        return v
    }

    /// Stops capture and closes the raw file. Returns its URL.
    func stop() async throws -> URL {
        let stopTime = Self.hostNow
        // Freeze the timeline right now: anything delivered after this is dropped.
        queue.sync { writer.pause(at: stopTime) }
        await stopStream()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.writer.finish(at: stopTime) { cont.resume(with: $0) }
            }
        }
    }

    func cancel() async {
        queue.sync { writer.pause(at: Self.hostNow) }
        await stopStream()
        queue.sync { writer.cancel() }
    }

    private func stopStream() async {
        let alreadyStopped: Bool = queue.sync {
            defer { stopped = true }
            return stopped
        }
        if !alreadyStopped { try? await stream.stopCapture() }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus),
                  status == .complete || status == .started,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            writer.appendVideo(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
            if writer.hasFailed, !failureReported {
                failureReported = true
                let err = RecorderError.writerFailed(writer.failureDescription)
                DispatchQueue.main.async { self.onUnexpectedStop?(err) }
            }
        case .audio:
            if let t = systemTrack { writer.appendAudio(sb, track: t) }
        case .microphone:
            if let t = micTrack {
                writer.appendAudio(sb, track: t)
                let p = AudioLevel.peak(of: sb)
                levelLock.lock(); _micPeak = max(_micPeak, p); levelLock.unlock()
            }
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            DispatchQueue.main.async { self.onUnexpectedStop?(error) }
        }
    }
}
