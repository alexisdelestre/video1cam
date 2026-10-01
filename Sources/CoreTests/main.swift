// Offline test of the recording pipeline with synthetic buffers.
// Simulates what ScreenCaptureKit delivers (host-clock timestamps, heterogeneous audio
// formats, gaps, jitter, static screen, pause) and checks A/V sync of the final MP4.
import AVFoundation
import CoreMedia
import RecorderCore

let base = 5000.0          // fake host clock origin (s)
let fps = 30.0
let width = 640, height = 360
let flashTimes = [2.0, 9.0]        // source time of white video frames
let beep0 = 9.0, beep1 = 2.0       // track 0 (has a gap) beeps after the gap + pause; track 1 (late start) at 2.0
let pauseRange = (6.0, 7.5)
let stopAt = 12.0
let staticScreen = (3.0, 5.0)      // no frames delivered
let audio0Gap = (4.0, 5.0)         // system audio stops delivering
let audio1Start = 1.0
func expectedOut(_ t: Double) -> Double { t >= pauseRange.1 ? t - (pauseRange.1 - pauseRange.0) : t }

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  ✓ \(msg)" : "  ✗ \(msg)")
    if !ok { failures += 1 }
}

func host(_ t: Double) -> CMTime { CMTime(seconds: base + t, preferredTimescale: 1_000_000_000) }

func pixelBuffer(white: Bool) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), white ? 255 : 20, CVPixelBufferGetDataSize(pb!))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

func audioBuffer(pts: CMTime, start: Double, frames: Int, rate: Double, channels: Int, beepAt: Double) -> CMSampleBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    for c in 0..<channels {
        for i in 0..<frames {
            let t = start + Double(i) / rate
            let inBeep = t >= beepAt && t < beepAt + 0.1
            pcm.floatChannelData![c][i] = inBeep ? Float(0.5 * sin(2 * .pi * 1000 * t)) : 0
        }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                         formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
                         sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
    CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList)
    CMSampleBufferSetDataReady(sb!)
    return sb!
}

enum Event { case video(Double), audio(track: Int, t: Double), pause(Double), resume(Double) }

func buildEvents(withAudio: Bool) -> [Event] {
    var events: [(Double, Event)] = []
    var t = 0.0
    while t < stopAt {
        if !(t >= staticScreen.0 && t < staticScreen.1) { events.append((t, .video(t))) }
        t += 1 / fps
    }
    if withAudio {
        let n0 = 1024.0 / 48000
        t = 0.0
        while t < stopAt {
            if !(t >= audio0Gap.0 && t < audio0Gap.1) { events.append((t, .audio(track: 0, t: t))) }
            t += n0
        }
        let n1 = 441.0 / 44100
        t = audio1Start
        var k = 0
        while t < stopAt {
            events.append((t, .audio(track: 1, t: t)))
            k += 1
            t = audio1Start + Double(k) * n1
        }
    }
    events.append((pauseRange.0, .pause(pauseRange.0)))
    events.append((pauseRange.1, .resume(pauseRange.1)))
    return events.sorted { $0.0 < $1.0 }.map { $0.1 }
}

func record(to url: URL, withAudio: Bool, crashAfter: Double? = nil) throws -> MovieWriter {
    let writer = try MovieWriter(url: url, video: VideoSettings(width: width, height: height, fps: 30, codec: .h264),
                                 audioTrackCount: withAudio ? 2 : 0)
    writer.waitsForReadiness = true
    var rng = SystemRandomNumberGenerator()
    for e in buildEvents(withAudio: withAudio) {
        switch e {
        case .video(let t):
            if let c = crashAfter, t > c { return writer }
            let white = flashTimes.contains { abs($0 - t) < 0.5 / fps }
            writer.appendVideo(pixelBuffer: pixelBuffer(white: white), pts: host(t))
        case .audio(let track, let t):
            if track == 0 {
                writer.appendAudio(audioBuffer(pts: host(t), start: t, frames: 1024, rate: 48000, channels: 2, beepAt: beep0), track: 0)
            } else {
                let jitter = Double(Int.random(in: -3...3, using: &rng)) / 1000 // ±3 ms clock jitter on the timestamp only
                writer.appendAudio(audioBuffer(pts: host(t + jitter), start: t, frames: 441, rate: 44100, channels: 1, beepAt: beep1), track: 1)
            }
        case .pause(let t): writer.pause(at: host(t))
        case .resume(let t): writer.resume(at: host(t))
        }
    }
    return writer
}

func finish(_ writer: MovieWriter) throws -> URL {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<URL, Error>!
    writer.finish(at: host(stopAt)) { result = $0; sem.signal() }
    sem.wait()
    return try result.get()
}

func finalize(_ raw: URL, _ out: URL) async throws {
    var last = -1.0
    try await Finalizer.finalize(input: raw, output: out) { p in last = p }
    check(last == 1, "progression atteint 100 %")
}

func analyze(_ url: URL, expectAudio: Bool, expectedDuration: Double, expectedFlashes: [Double], expectedBeeps: [Double]) async throws {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let duration = try await asset.load(.duration).seconds
    let v = try await asset.loadTracks(withMediaType: .video)
    let a = try await asset.loadTracks(withMediaType: .audio)
    check(v.count == 1, "1 piste vidéo")
    check(a.count == (expectAudio ? 1 : 0), "\(expectAudio ? 1 : 0) piste audio (trouvé \(a.count))")
    check(abs(duration - expectedDuration) < 0.1, String(format: "durée %.3f s (attendu %.3f)", duration, expectedDuration))
    let vfmt = try await v[0].load(.formatDescriptions)[0]
    check(CMFormatDescriptionGetMediaSubType(vfmt) == kCMVideoCodecType_H264, "codec H.264")
    let vr = try await v[0].load(.timeRange)
    check(abs(vr.end.seconds - expectedDuration) < 0.1, String(format: "vidéo couvre jusqu'à %.3f s", vr.end.seconds))

    // Video: find white frames.
    let reader = try AVAssetReader(asset: asset)
    let vo = AVAssetReaderTrackOutput(track: v[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(vo)
    var ao: AVAssetReaderTrackOutput?
    if expectAudio {
        let o = AVAssetReaderTrackOutput(track: a[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(o); ao = o
    }
    reader.startReading()
    var flashes: [Double] = []
    var prevWhite = false
    var frameCount = 0
    while let sb = vo.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        frameCount += 1
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let off = (height / 2) * CVPixelBufferGetBytesPerRow(pb) + (width / 2) * 4
        let white = p[off + 1] > 128
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        if white && !prevWhite { flashes.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        prevWhite = white
    }
    print("    images: \(frameCount), flashs à \(flashes.map { String(format: "%.3f", $0) })")
    check(flashes.count == expectedFlashes.count, "\(expectedFlashes.count) flashs détectés")
    for (f, e) in zip(flashes, expectedFlashes) { check(abs(f - e) < 1.5 / fps, String(format: "flash %.3f ≈ %.3f", f, e)) }

    if let ao {
        var beeps: [Double] = []
        var lastLoud = -10.0
        var totalFrames = 0
        var peak: Float = 0
        while let sb = ao.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let n = CMSampleBufferGetNumSamples(sb)
            var abl = AudioBufferList()
            var block: CMBlockBuffer?
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
                                                                    bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                                                                    blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            let ch = Int(abl.mBuffers.mNumberChannels)
            let samples = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let s = abs(samples[i * ch])
                peak = max(peak, s)
                let t = pts + Double(i) / 48000
                if s > 0.1 {
                    if t - lastLoud > 0.5 { beeps.append(t) }
                    lastLoud = t
                }
            }
            totalFrames += n
        }
        let audioDur = Double(totalFrames) / 48000
        print("    audio: \(String(format: "%.3f", audioDur)) s, pic \(peak), bips à \(beeps.map { String(format: "%.3f", $0) })")
        check(abs(audioDur - expectedDuration) < 0.15, String(format: "durée audio %.3f ≈ %.3f", audioDur, expectedDuration))
        check(beeps.count == expectedBeeps.count, "\(expectedBeeps.count) bips détectés")
        // AAC priming/encoder delay is compensated by AVFoundation; allow 25 ms.
        for (b, e) in zip(beeps, expectedBeeps) { check(abs(b - e) < 0.025, String(format: "bip %.3f ≈ %.3f (écart %+.1f ms)", b, e, (b - e) * 1000)) }
    }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video1cam-tests-\(getpid())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let expectedDuration = stopAt - (pauseRange.1 - pauseRange.0)

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "crash-child" {
    // Child process: record half, then die without finishing the file.
    _ = try record(to: URL(fileURLWithPath: CommandLine.arguments[2]), withAudio: true, crashAfter: 10.5)
    usleep(300_000)
    exit(0) // abrupt: writer never finished
}

print("Scénario 1 : écran + 2 pistes audio (formats différents, trous, gigue, pause, écran statique)")
do {
    let raw = dir.appendingPathComponent("raw1.mov"), out = dir.appendingPathComponent("out1.mp4")
    let url = try finish(try record(to: raw, withAudio: true))
    check(FileManager.default.fileExists(atPath: url.path), "fichier brut écrit")
    try await finalize(raw, out)
    try await analyze(out, expectAudio: true, expectedDuration: expectedDuration,
                      expectedFlashes: flashTimes.map(expectedOut), expectedBeeps: [expectedOut(beep1), expectedOut(beep0)])
    let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("    taille mp4: \(size / 1024) Ko")
}

print("Scénario 2 : écran seul, sans audio")
do {
    let raw = dir.appendingPathComponent("raw2.mov"), out = dir.appendingPathComponent("out2.mp4")
    _ = try finish(try record(to: raw, withAudio: false))
    try await finalize(raw, out)
    try await analyze(out, expectAudio: false, expectedDuration: expectedDuration,
                      expectedFlashes: flashTimes.map(expectedOut), expectedBeeps: [])
}

print("Scénario 3 : aucune image reçue → erreur propre")
do {
    let raw = dir.appendingPathComponent("raw3.mov")
    let w = try MovieWriter(url: raw, video: VideoSettings(width: width, height: height, fps: 30, codec: .h264), audioTrackCount: 1)
    do { _ = try finish(w); check(false, "erreur attendue") }
    catch { check(error is RecorderError, "erreur: \(error.localizedDescription)") }
    check(!FileManager.default.exists(raw), "fichier brut supprimé")
}

print("Scénario 4 : crash en cours d'enregistrement → fichier brut récupérable")
do {
    let raw = dir.appendingPathComponent("raw4.mov"), out = dir.appendingPathComponent("out4.mp4")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["crash-child", raw.path]
    try p.run(); p.waitUntilExit()
    check(FileManager.default.exists(raw), "fichier brut présent après crash")
    do {
        try await Finalizer.finalize(input: raw, output: out)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        check(d > 5, String(format: "récupéré %.1f s de vidéo", d))
    } catch { check(false, "récupération: \(error.localizedDescription)") }
}

print("Scénario 5 : HEVC")
do {
    let raw = dir.appendingPathComponent("raw5.mov")
    let w = try MovieWriter(url: raw, video: VideoSettings(width: 1280, height: 720, fps: 30, codec: .hevc), audioTrackCount: 0)
    w.waitsForReadiness = true
    for i in 0..<30 { w.appendVideo(pixelBuffer: pixelBuffer(white: i % 2 == 0), pts: host(Double(i) / 30)) }
    let sem = DispatchSemaphore(value: 0); var r: Result<URL, Error>!
    w.finish(at: host(1)) { r = $0; sem.signal() }; sem.wait()
    check((try? r.get()) != nil, "HEVC écrit")
}

print("Scénario 6 : utilitaires (nommage, résolution, niveau audio)")
do {
    check(FileNaming.slug("Passation module Facturation é/2 !") == "passation-module-facturation-e-2", "slug: \(FileNaming.slug("Passation module Facturation é/2 !"))")
    check(FileNaming.slug("  Œuvre — Démo : Été  ") == "oeuvre-demo-ete", "slug: \(FileNaming.slug("  Œuvre — Démo : Été  "))")
    check(FileNaming.slug("///") == "", "slug vide")
    var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 3; comps.hour = 9; comps.minute = 5
    let d = Calendar.current.date(from: comps)!
    check(FileNaming.baseName(date: d, title: "") == "2026-09-03_09-05_enregistrement", FileNaming.baseName(date: d, title: ""))
    let u1 = FileNaming.uniqueURL(in: dir, base: "x", ext: "mp4")
    FileManager.default.createFile(atPath: u1.path, contents: Data())
    let u2 = FileNaming.uniqueURL(in: dir, base: "x", ext: "mp4")
    check(u2.lastPathComponent == "x-2.mp4", "pas d'écrasement: \(u2.lastPathComponent)")
    check(FileNaming.uniqueURL(in: dir, base: "x", ext: "mp4", except: u1) == u1, "renommer vers soi-même autorisé")

    let a = OutputSize.compute(points: CGSize(width: 1440, height: 900), scale: 2, maxLong: 1920, maxShort: 1080)
    check(a.width == 1728 && a.height == 1080, "retina 1440×900 → \(a.width)×\(a.height)")
    let b = OutputSize.compute(points: CGSize(width: 2560, height: 1440), scale: 2, maxLong: 3840, maxShort: 2160)
    check(b.width == 3840 && b.height == 2160, "5K → 4K: \(b.width)×\(b.height)")
    let c = OutputSize.compute(points: CGSize(width: 333, height: 201), scale: 1, maxLong: 1920, maxShort: 1080)
    check(c.width % 2 == 0 && c.height % 2 == 0 && c.width == 334 && c.height == 202, "dimensions paires: \(c.width)×\(c.height)")
    let e = OutputSize.compute(points: CGSize(width: 900, height: 1600), scale: 2, maxLong: 1920, maxShort: 1080)
    check(e.width == 1080 && e.height == 1920, "portrait: \(e.width)×\(e.height)")

    let sb = audioBuffer(pts: host(0), start: 9.0, frames: 4800, rate: 48000, channels: 2, beepAt: 9.0)
    let pk = AudioLevel.peak(of: sb)
    check(pk > 0.45 && pk <= 0.5001, "niveau crête float non entrelacé: \(pk)")
    let silent = audioBuffer(pts: host(0), start: 0, frames: 480, rate: 48000, channels: 1, beepAt: 99)
    check(AudioLevel.peak(of: silent) == 0, "silence = 0")
}

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "\nTOUS LES TESTS PASSENT" : "\n\(failures) ÉCHEC(S)")
exit(failures == 0 ? 0 : 1)

extension FileManager { func exists(_ u: URL) -> Bool { fileExists(atPath: u.path) } }
