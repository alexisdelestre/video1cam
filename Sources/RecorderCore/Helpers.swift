import AVFoundation
import CoreMedia
import Foundation

public enum FileNaming {
    /// "Passation module Facturation é/2" → "passation-module-facturation-e-2"
    public static func slug(_ s: String, maxLength: Int = 80) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
            .lowercased()
        var out = ""
        var lastDash = true
        for ch in folded.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    public static func datePrefix(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f.string(from: date)
    }

    /// "2026-09-30_15-42_passation-facturation"
    public static func baseName(date: Date, title: String) -> String {
        let s = slug(title)
        return "\(datePrefix(date))_\(s.isEmpty ? "enregistrement" : s)"
    }

    /// Never overwrites: appends -2, -3… if needed. `except` is a file allowed to be "replaced" (itself).
    public static func uniqueURL(in dir: URL, base: String, ext: String, except: URL? = nil) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              candidate.standardizedFileURL.path != except?.standardizedFileURL.path {
            candidate = dir.appendingPathComponent("\(base)-\(i).\(ext)")
            i += 1
        }
        return candidate
    }
}

public enum OutputSize {
    /// Pixel size for a capture of `points` at `scale`, fitted into maxLong×maxShort, even dimensions.
    public static func compute(points: CGSize, scale: CGFloat, maxLong: Int, maxShort: Int) -> (width: Int, height: Int) {
        let pw = Double(points.width * scale), ph = Double(points.height * scale)
        guard pw >= 1, ph >= 1 else { return (2, 2) }
        let long = max(pw, ph), short = min(pw, ph)
        let f = min(1.0, Double(maxLong) / long, Double(maxShort) / short)
        func even(_ v: Double) -> Int { max(2, Int((v * f / 2).rounded()) * 2) }
        return (even(pw), even(ph))
    }
}

public enum AudioLevel {
    /// Peak amplitude (0…1) of an LPCM sample buffer (float32 or int16/int32, interleaved or not).
    public static func peak(of sb: CMSampleBuffer) -> Float {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &block) == noErr else { return 0 }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(abl) {
            guard let data = buf.mData else { continue }
            let bytes = Int(buf.mDataByteSize)
            if isFloat && asbd.mBitsPerChannel == 32 {
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<(bytes / 4) { peak = max(peak, abs(p[i])) }
            } else if !isFloat && asbd.mBitsPerChannel == 16 {
                let p = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<(bytes / 2) { peak = max(peak, abs(Float(p[i])) / 32768) }
            } else if !isFloat && asbd.mBitsPerChannel == 32 {
                let p = data.assumingMemoryBound(to: Int32.self)
                for i in 0..<(bytes / 4) { peak = max(peak, abs(Float(p[i])) / 2_147_483_648) }
            }
        }
        return min(1, peak)
    }
}
