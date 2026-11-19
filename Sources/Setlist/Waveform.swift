import SwiftUI
import AVFoundation

/// Computes and caches downsampled peak envelopes for audio files, off the main
/// thread. Peaks span the whole file (0…1, one per bucket).
final class WaveformStore: ObservableObject {
    static let shared = WaveformStore()
    static let buckets = 900

    @Published private(set) var peaks: [String: [Float]] = [:]
    private var loading: Set<String> = []

    /// Cached peaks for `path`, starting a background read if needed.
    func peaks(for path: String) -> [Float]? {
        if let p = peaks[path] { return p }
        guard !loading.contains(path) else { return nil }
        loading.insert(path)
        DispatchQueue.global(qos: .utility).async {
            let p = Self.compute(URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                self.loading.remove(path)
                if let p { self.peaks[path] = p }
            }
        }
        return nil
    }

    private static func compute(_ url: URL) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        let fmt = f.processingFormat
        let channels = Int(fmt.channelCount)
        let framesPerBucket = max(1, Double(f.length) / Double(buckets))
        var out = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var pos: AVAudioFramePosition = 0
        while pos < f.length {
            do { try f.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for i in 0..<n {
                var m: Float = 0
                for c in 0..<channels { m = max(m, abs(data[c][i])) }
                let b = min(buckets - 1, Int(Double(pos + AVAudioFramePosition(i)) / framesPerBucket))
                if m > out[b] { out[b] = m }
            }
            pos += AVAudioFramePosition(n)
        }
        // Normalise so quiet classical recordings still read clearly.
        let top = max(out.max() ?? 1, 0.0001)
        return out.map { min(1, $0 / top) }
    }
}

/// Mirrored bar waveform for the part of the file between `from` and `to`
/// (seconds), coloured `played` up to `progress` (absolute seconds).
struct WaveformShape: View {
    let peaks: [Float]
    let duration: Double
    var from: Double = 0
    var to: Double? = nil
    var progress: Double? = nil
    var played: Color = Theme.ink
    var unplayed: Color = Color(hex: 0xD4D4D4)
    var barWidth: CGFloat = 2
    var gap: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0, !peaks.isEmpty else { return }
            let end = to ?? duration
            let span = max(0.001, end - from)
            let step = barWidth + gap
            let count = max(1, Int(size.width / step))
            let mid = size.height / 2
            for i in 0..<count {
                let t0 = from + span * Double(i) / Double(count)
                let t1 = from + span * Double(i + 1) / Double(count)
                let b0 = Int(t0 / duration * Double(peaks.count))
                let b1 = max(b0 + 1, Int(t1 / duration * Double(peaks.count)))
                var v: Float = 0
                for b in max(0, b0)..<min(peaks.count, b1) { v = max(v, peaks[b]) }
                let h = max(1.5, CGFloat(v) * size.height)
                let x = CGFloat(i) * step
                let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                let isPlayed = progress.map { t0 < $0 } ?? false
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(isPlayed ? played : unplayed))
            }
        }
    }
}

/// Waveform scrubber for the transport: shows the playable segment, click or
/// drag anywhere to jump there.
struct WaveformScrubber: View {
    @ObservedObject private var store = WaveformStore.shared
    let track: Track?
    let position: Double          // absolute seconds
    let start: Double
    let end: Double
    let onSeek: (Double) -> Void

    @State private var dragPos: Double?
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let span = max(0.001, end - start)
            let shown = dragPos ?? position
            ZStack(alignment: .leading) {
                if let t = track, let peaks = store.peaks(for: t.path) {
                    WaveformShape(peaks: peaks, duration: max(t.duration, end), from: start, to: end,
                                  progress: shown)
                } else {
                    Capsule().fill(Color(hex: 0xE6E6E6)).frame(height: 2)
                        .frame(maxHeight: .infinity)
                }
                if track != nil {
                    // playhead
                    Rectangle().fill(Theme.blue)
                        .frame(width: 2)
                        .offset(x: CGFloat((shown - start) / span) * w - 1)
                    if let hx = hoverX, dragPos == nil {
                        Rectangle().fill(Theme.ink.opacity(0.25)).frame(width: 1).offset(x: hx)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard track != nil else { return }
                        dragPos = start + span * Double(min(max(0, g.location.x / w), 1))
                    }
                    .onEnded { _ in
                        if let p = dragPos { onSeek(p) }
                        dragPos = nil
                    }
            )
        }
    }
}

/// Waveform of the whole file with draggable start/end handles for trimming.
struct WaveformTrimmer: View {
    @ObservedObject private var store = WaveformStore.shared
    let track: Track
    let position: Double?         // playhead if this track is loaded
    let onStart: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let dur = max(track.duration, 0.001)
            let sx = CGFloat(track.trimStart / dur) * w
            let ex = CGFloat(track.effectiveEnd / dur) * w
            ZStack(alignment: .leading) {
                if let peaks = store.peaks(for: track.path) {
                    WaveformShape(peaks: peaks, duration: dur, unplayed: Theme.ink.opacity(0.75))
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // dim the trimmed-away regions
                Rectangle().fill(Theme.paper.opacity(0.78)).frame(width: max(0, sx))
                Rectangle().fill(Theme.paper.opacity(0.78)).frame(width: max(0, w - ex)).offset(x: ex)
                if let p = position {
                    Rectangle().fill(Theme.blue).frame(width: 2).offset(x: CGFloat(p / dur) * w - 1)
                }
                handle.offset(x: sx - 5)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { g in
                        onStart(min(Double(g.location.x / w) * dur, track.effectiveEnd - 0.1))
                    })
                handle.offset(x: ex - 5)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { g in
                        onEnd(max(Double(g.location.x / w) * dur, track.trimStart + 0.1))
                    })
            }
            .coordinateSpace(name: "trim")
        }
    }

    private var handle: some View {
        ZStack {
            Rectangle().fill(Theme.ink).frame(width: 2)
            Capsule().fill(Theme.ink).frame(width: 10, height: 22)
        }
        .frame(width: 10)
        .contentShape(Rectangle().inset(by: -6))
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}
