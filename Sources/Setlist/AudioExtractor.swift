import AVFoundation
import UniformTypeIdentifiers

/// Pulls the soundtrack out of a video into a lossless (Apple Lossless) audio
/// file, so video tracks play, analyze, and draw waveforms like any audio file.
/// The original video is never modified.
enum AudioExtractor {
    enum Failure: LocalizedError {
        case noAudio, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "the video has no audio track"
            case .unreadable(let why): return why
            }
        }
    }

    /// True for movie files (anything that isn't plain audio but has video).
    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]

    /// Where extracted audio lives — next to the library file.
    static func cacheFolder(libraryURL: URL) -> URL {
        let dir = libraryURL.deletingLastPathComponent().appendingPathComponent("Extracted Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Decode the first audio track of `video` and write it to `dest` (.m4a, ALAC).
    /// Multichannel audio is downmixed to stereo. Returns the duration in seconds.
    static func extract(video: URL, to dest: URL) async throws -> Double {
        let asset = AVURLAsset(url: video)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch {
            throw Failure.unreadable("the video couldn't be read (\(error.localizedDescription))")
        }
        guard let track = tracks.first else { throw Failure.noAudio }

        var sampleRate = 48_000.0
        var channels = 2
        if let desc = try? await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            channels = asbd.mChannelsPerFrame == 1 ? 1 : 2
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // The mix output handles channel-count conversion (e.g. 5.1 → stereo).
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable("unsupported audio format") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "couldn't start reading")
        }

        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let alac: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitDepthHintKey: 24,
        ]
        var frames: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: alac,
                                       commonFormat: .pcmFormatFloat32, interleaved: true)
            let fmt = file.processingFormat
            while let sample = output.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sample)
                guard n > 0, let block = CMSampleBufferGetDataBuffer(sample),
                      let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)),
                      let dst = buf.audioBufferList.pointee.mBuffers.mData else { continue }
                let bytes = n * Int(fmt.streamDescription.pointee.mBytesPerFrame)
                guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: dst) == noErr else { continue }
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                frames += AVAudioFramePosition(n)
            }
        }   // file closes here
        if reader.status == .failed {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "reading failed")
        }
        guard frames > 0 else { throw Failure.noAudio }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return Double(frames) / sampleRate
    }
}
