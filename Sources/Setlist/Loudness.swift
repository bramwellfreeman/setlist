import Foundation
import AVFoundation

/// Second-order IIR section, transposed Direct-Form II (a0 normalised to 1).
private struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1: Double = 0, z2: Double = 0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Integrated loudness measurement per ITU-R BS.1770 / EBU R128.
enum Loudness {

    /// K-weighting: stage 1 high-shelf "pre-filter" + stage 2 RLB high-pass.
    /// Coefficients derived per sample rate (matching pyloudnorm), so any rate works.
    private static func kWeighting(_ fs: Double) -> (Biquad, Biquad) {
        // Stage 1 — high shelf.
        let f0s = 1681.974450955533
        let Gs  = 3.999843853973347
        let Qs  = 0.7071752369554196
        let Ks  = tan(.pi * f0s / fs)
        let Vh  = pow(10.0, Gs / 20.0)
        let Vb  = pow(Vh, 0.4996667741545416)
        let a0s = 1.0 + Ks / Qs + Ks * Ks
        let shelf = Biquad(
            b0: (Vh + Vb * Ks / Qs + Ks * Ks) / a0s,
            b1: 2.0 * (Ks * Ks - Vh) / a0s,
            b2: (Vh - Vb * Ks / Qs + Ks * Ks) / a0s,
            a1: 2.0 * (Ks * Ks - 1.0) / a0s,
            a2: (1.0 - Ks / Qs + Ks * Ks) / a0s)

        // Stage 2 — RLB high pass.
        let f0h = 38.13547087602444
        let Qh  = 0.5003270373238773
        let Kh  = tan(.pi * f0h / fs)
        let a0h = 1.0 + Kh / Qh + Kh * Kh
        let hp = Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (Kh * Kh - 1.0) / a0h,
            a2: (1.0 - Kh / Qh + Kh * Kh) / a0h)

        return (shelf, hp)
    }

    /// Returns the integrated loudness (LUFS) over [start, end] seconds, or nil
    /// if the segment is too short or effectively silent.
    static func integratedLUFS(file url: URL, start: Double, end: Double) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat
        let fs = fmt.sampleRate
        let channels = Int(fmt.channelCount)
        guard channels > 0, fs > 0 else { return nil }

        let total = f.length
        var startFrame = AVAudioFramePosition(max(0, start) * fs)
        var endFrame = (end <= 0) ? total : AVAudioFramePosition(end * fs)
        endFrame = min(endFrame, total)
        startFrame = max(0, min(startFrame, endFrame))
        if startFrame >= endFrame { return nil }
        f.framePosition = startFrame

        var filters = (0..<channels).map { _ in kWeighting(fs) }

        let subBlock = Int((0.1 * fs).rounded())        // 100 ms
        guard subBlock > 0 else { return nil }
        var subSum = [Double](repeating: 0, count: channels)
        var subCount = 0
        var subMeans: [[Double]] = []                    // per 100 ms: mean-square per channel

        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        var remaining = endFrame - startFrame

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            buf.frameLength = 0
            do { try f.read(into: buf, frameCount: toRead) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            remaining -= AVAudioFramePosition(n)
            guard let data = buf.floatChannelData else { break }
            for i in 0..<n {
                for c in 0..<channels {
                    var (s1, s2) = filters[c]
                    let y = s2.process(s1.process(Double(data[c][i])))
                    filters[c] = (s1, s2)
                    subSum[c] += y * y
                }
                subCount += 1
                if subCount == subBlock {
                    var means = [Double](repeating: 0, count: channels)
                    for c in 0..<channels { means[c] = subSum[c] / Double(subBlock); subSum[c] = 0 }
                    subMeans.append(means)
                    subCount = 0
                }
            }
        }

        if subMeans.count < 4 { return nil }             // need at least one 400 ms block

        // 400 ms gating blocks, stepped every 100 ms (75% overlap).
        var loudness: [Double] = []
        var zsums: [Double] = []
        for i in 0...(subMeans.count - 4) {
            var zsum = 0.0
            for c in 0..<channels {
                let z = (subMeans[i][c] + subMeans[i+1][c] + subMeans[i+2][c] + subMeans[i+3][c]) / 4.0
                zsum += z                                 // channel weight = 1.0 (mono/stereo)
            }
            if zsum <= 0 { continue }
            loudness.append(-0.691 + 10.0 * log10(zsum))
            zsums.append(zsum)
        }
        if zsums.isEmpty { return nil }

        // Absolute gate at -70 LUFS.
        var absZ: [Double] = []
        for (i, l) in loudness.enumerated() where l >= -70.0 { absZ.append(zsums[i]) }
        if absZ.isEmpty { return nil }
        let meanAbs = absZ.reduce(0, +) / Double(absZ.count)
        let relThresh = -0.691 + 10.0 * log10(meanAbs) - 10.0

        // Relative gate.
        var finalZ: [Double] = []
        for (i, l) in loudness.enumerated() where l >= -70.0 && l >= relThresh { finalZ.append(zsums[i]) }
        if finalZ.isEmpty { return nil }
        let meanZ = finalZ.reduce(0, +) / Double(finalZ.count)
        return -0.691 + 10.0 * log10(meanZ)
    }
}
