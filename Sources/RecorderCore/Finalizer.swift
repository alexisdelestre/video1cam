@preconcurrency import AVFoundation
import CoreMedia

/// Converts the raw recording into a portable MP4:
/// video is passed through untouched, all audio tracks are mixed into a single AAC track
/// (players usually only play the first audio track), moov atom placed first for streaming.
public enum Finalizer {
    public static func finalize(input: URL, output: URL, trackVolumes: [Float] = [],
                                progress: ((Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        var audioTracks: [AVAssetTrack] = []
        for t in try await asset.loadTracks(withMediaType: .audio) {
            let range = try await t.load(.timeRange)
            if range.duration.seconds > 0.05 { audioTracks.append(t) }
        }
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let transform = try await videoTrack.load(.preferredTransform)

        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoIn.transform = transform
        writer.add(videoIn)

        var audioOut: AVAssetReaderAudioMixOutput?
        var audioIn: AVAssetWriterInput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.enumerated().map { i, t in
                let p = AVMutableAudioMixInputParameters(track: t)
                p.setVolume(i < trackVolumes.count ? trackVolumes[i] : 1.0, at: .zero)
                return p
            }
            out.audioMix = mix
            reader.add(out)
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            writer.add(inp)
            audioOut = out
            audioIn = inp
        }

        guard reader.startReading() else {
            throw RecorderError.exportFailed(reader.error?.localizedDescription ?? "lecture impossible")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RecorderError.exportFailed(writer.error?.localizedDescription ?? "écriture impossible")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration.seconds, 0.001)
        let group = DispatchGroup()
        let failed = FailureFlag()

        func pump(_ readerOutput: AVAssetReaderOutput, into writerInput: AVAssetWriterInput, label: String, reportProgress: Bool) {
            // Each pair is only ever touched from its own serial queue.
            nonisolated(unsafe) let output = readerOutput
            nonisolated(unsafe) let input = writerInput
            group.enter()
            let queue = DispatchQueue(label: "finalizer.\(label)")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if failed.value {
                        input.markAsFinished(); group.leave(); return
                    }
                    guard let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); group.leave(); return
                    }
                    if !input.append(sb) {
                        failed.set()
                        input.markAsFinished(); group.leave(); return
                    }
                    if reportProgress, let progress {
                        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        if t.isFinite { progress(min(1, t / total)) }
                    }
                }
            }
        }

        pump(videoOut, into: videoIn, label: "video", reportProgress: true)
        if let audioOut, let audioIn { pump(audioOut, into: audioIn, label: "audio", reportProgress: false) }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        if failed.value || reader.status == .failed {
            let msg = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "erreur inconnue"
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw RecorderError.exportFailed(msg)
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw RecorderError.exportFailed(writer.error?.localizedDescription ?? "statut \(writer.status.rawValue)")
        }
        progress?(1)
    }
}

private final class FailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}
