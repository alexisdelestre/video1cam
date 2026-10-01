import AVFoundation
import CoreMedia

public enum RecorderError: LocalizedError {
    case noVideoFrames
    case writerFailed(String)
    case noVideoTrack
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoFrames: return "Aucune image n'a été capturée."
        case .writerFailed(let m): return "Échec de l'écriture vidéo : \(m)"
        case .noVideoTrack: return "Le fichier brut ne contient pas de piste vidéo."
        case .exportFailed(let m): return "Échec de la finalisation : \(m)"
        }
    }
}

public struct VideoSettings {
    public enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        public var id: String { rawValue }
        var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
    }

    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: Codec

    public init(width: Int, height: Int, fps: Int, codec: Codec) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
    }

    /// Screen content compresses well: ~0.07 bit/pixel at H.264, HEVC gets ~35% less.
    public var bitrate: Int {
        let bpp = codec == .h264 ? 0.07 : 0.045
        return max(1_000_000, Int(Double(width * height * fps) * bpp))
    }
}

/// Writes screen frames + N audio tracks into a crash-tolerant (fragmented) QuickTime file.
///
/// Not thread-safe: every method must be called from the same serial queue.
/// All timestamps are expected on the host time clock (as delivered by ScreenCaptureKit).
public final class MovieWriter {
    public let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioTracks: [AudioTrackState] = []

    private var sessionStart: CMTime?
    private var lastVideoPTS: CMTime = .negativeInfinity   // adjusted timeline
    private var lastPixelBuffer: CVPixelBuffer?

    // Pause bookkeeping, in source (host clock) time.
    private var pauses: [CMTimeRange] = []
    private var pauseStart: CMTime?
    private var finished = false

    /// Maximum tolerated drift between the audio sample count and the clock before correcting.
    static let driftTolerance = CMTime(value: 20, timescale: 1000)

    /// Tests only: block until the writer is ready instead of dropping samples.
    public var waitsForReadiness = false {
        didSet { audioTracks.forEach { $0.waitsForReadiness = waitsForReadiness } }
    }

    public var isPaused: Bool { pauseStart != nil }
    public var hasStarted: Bool { sessionStart != nil }
    /// True once AVAssetWriter has failed (disk full, encoder error…): nothing more gets written.
    public var hasFailed: Bool { writer.status == .failed }
    public var failureDescription: String { writer.error?.localizedDescription ?? "erreur inconnue" }

    public init(url: URL, video: VideoSettings, audioTrackCount: Int) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments make the file readable even if the app crashes mid-recording.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: video.bitrate,
            AVVideoExpectedSourceFrameRateKey: video.fps,
            AVVideoMaxKeyFrameIntervalKey: video.fps * 2,
        ]
        if video.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAllowFrameReorderingKey] = false
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: video.codec.avCodec,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw RecorderError.writerFailed("réglages vidéo non supportés (\(video.width)×\(video.height) \(video.codec.rawValue))")
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        // Lossless intermediate audio; the writer converts any source rate/channel count.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        for _ in 0..<audioTrackCount {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioTracks.append(AudioTrackState(input: input))
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
    }

    // MARK: - Timeline

    /// Returns the timestamp on the output timeline, or nil if the sample must be dropped (paused / before start).
    private func adjusted(_ pts: CMTime) -> CMTime? {
        guard let start = sessionStart, pts >= start else { return nil }
        if let ps = pauseStart, pts >= ps { return nil }
        var offset = CMTime.zero
        for p in pauses {
            if pts >= p.end { offset = offset + p.duration }
            else if pts >= p.start { return nil }
        }
        return pts - offset
    }

    public func pause(at hostTime: CMTime) {
        guard !finished, pauseStart == nil else { return }
        pauseStart = hostTime
    }

    public func resume(at hostTime: CMTime) {
        guard let ps = pauseStart else { return }
        pauseStart = nil
        if hostTime > ps { pauses.append(CMTimeRange(start: ps, end: hostTime)) }
    }

    /// Duration recorded so far (excluding pauses), for UI display.
    public func recordedDuration(at hostTime: CMTime) -> TimeInterval {
        guard let start = sessionStart else { return 0 }
        var end = pauseStart ?? hostTime
        for p in pauses { end = end - p.duration }
        return max(0, (end - start).seconds)
    }

    // MARK: - Video

    /// Appends a screen frame. `pixelBuffer` must match the configured size.
    public func appendVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard !finished, writer.status == .writing else { return }
        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        guard let t = adjusted(pts), t > lastVideoPTS else { return }
        lastPixelBuffer = pixelBuffer
        if waitsForReadiness { while !videoInput.isReadyForMoreMediaData { usleep(500) } }
        guard videoInput.isReadyForMoreMediaData else { return } // real time: drop the frame
        if adaptor.append(pixelBuffer, withPresentationTime: t) {
            lastVideoPTS = t
        }
    }

    // MARK: - Audio

    public func appendAudio(_ sampleBuffer: CMSampleBuffer, track: Int) {
        guard !finished, writer.status == .writing, audioTracks.indices.contains(track) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric, let t = adjusted(pts) else { return }
        audioTracks[track].append(sampleBuffer, at: t)
    }

    // MARK: - Finish

    public func finish(at hostTime: CMTime, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !finished else { return }
        finished = true
        if pauseStart != nil { resume(at: hostTime) }

        guard writer.status == .writing else {
            // Keep whatever was written (fragments are readable) so the caller can rescue it.
            completion(.failure(RecorderError.writerFailed(writer.error?.localizedDescription ?? "statut \(writer.status.rawValue)")))
            return
        }
        guard sessionStart != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(RecorderError.noVideoFrames))
            return
        }
        // End time on the output timeline.
        var end = hostTime
        for p in pauses { end = end - p.duration }
        // A static screen yields no frames: repeat the last one so video lasts as long as audio.
        if let pb = lastPixelBuffer, end > lastVideoPTS {
            var waited = 0
            while !videoInput.isReadyForMoreMediaData && waited < 200 { usleep(5_000); waited += 1 }
            if videoInput.isReadyForMoreMediaData, adaptor.append(pb, withPresentationTime: end) {
                lastVideoPTS = end
            }
        }
        lastPixelBuffer = nil
        videoInput.markAsFinished()
        for a in audioTracks { a.input.markAsFinished() }
        writer.endSession(atSourceTime: max(end, lastVideoPTS))
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(RecorderError.writerFailed(writer.error?.localizedDescription ?? "statut \(writer.status.rawValue)")))
            }
        }
    }

    public func cancel() {
        guard !finished else { return }
        finished = true
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

/// AVAssetWriter concatenates audio samples and ignores timestamp gaps, so we keep the
/// sample count aligned with the clock: gaps are filled with silence, overlaps are dropped.
final class AudioTrackState {
    let input: AVAssetWriterInput
    /// Where the next sample would land on the output timeline if appended contiguously.
    private var nextPTS: CMTime?
    var waitsForReadiness = false

    init(input: AVAssetWriterInput) { self.input = input }

    func append(_ sb: CMSampleBuffer, at t: CMTime) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mSampleRate > 0 else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        let rate = CMTimeScale(asbd.mSampleRate.rounded())
        let duration = CMTime(value: CMTimeValue(frames), timescale: rate)

        if let expected = nextPTS {
            let delta = t - expected
            if delta < CMTime.zero - MovieWriter.driftTolerance {
                return // overlap: drop, the next buffer will re-sync
            }
            if delta > MovieWriter.driftTolerance, asbd.mFormatID == kAudioFormatLinearPCM {
                // Never lose track of where the samples really are: if the fill stops early,
                // the next buffer will fill the remaining gap.
                let reached = appendSilence(from: expected, duration: delta, format: fmt, asbd: asbd)
                nextPTS = reached
                if reached < t - MovieWriter.driftTolerance { return }
            }
        }
        let at = nextPTS ?? t
        if waitsForReadiness { while !input.isReadyForMoreMediaData { usleep(500) } }
        guard input.isReadyForMoreMediaData else { return } // dropped; the gap gets filled next time
        let buffer = (at == CMSampleBufferGetPresentationTimeStamp(sb)) ? sb : retimed(sb, to: at, rate: rate) ?? sb
        if input.append(buffer) {
            nextPTS = at + duration
        }
    }

    private func retimed(_ sb: CMSampleBuffer, to t: CMTime, rate: CMTimeScale) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return st == noErr ? out : nil
    }

    private func appendSilence(from start: CMTime, duration: CMTime, format: CMAudioFormatDescription, asbd: AudioStreamBasicDescription) -> CMTime {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return start }
        let avFormat = AVAudioFormat(cmAudioFormatDescription: format)
        let rate = CMTimeScale(asbd.mSampleRate.rounded())
        var remaining = CMTimeValue((duration.seconds * Double(rate)).rounded())
        var cursor = start
        while remaining > 0 {
            let frames = Int(min(remaining, CMTimeValue(rate) / 10)) // 100 ms chunks
            guard let pcm = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)) else { return cursor }
            pcm.frameLength = AVAudioFrameCount(frames)
            for buf in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: cursor, decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                       formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr,
                  let sb,
                  CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                 flags: 0, bufferList: pcm.audioBufferList) == noErr,
                  CMSampleBufferSetDataReady(sb) == noErr else { return cursor }
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 100 { usleep(2_000); waited += 1 }
            guard input.isReadyForMoreMediaData, input.append(sb) else { return cursor }
            remaining -= CMTimeValue(frames)
            cursor = cursor + CMTime(value: CMTimeValue(frames), timescale: rate)
        }
        return cursor
    }
}
