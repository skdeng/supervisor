import Accelerate
import Foundation

/// FFT analysis of the tapped system audio: six log-spaced equalizer bands plus a bass-driven
/// "aura" envelope that swells on beats.
///
/// Not thread-safe by design — it is owned by `SystemAudioTap` and touched exclusively on the
/// tap's IO queue. Feed mono samples with `process`; roughly every `hopSize` samples it runs one
/// windowed FFT over the trailing `fftSize` samples and returns a fresh analysis frame.
///
/// Levels are self-normalizing: each band tracks its own slowly-decaying peak and reports its
/// current power relative to that, so the bars dance across quiet and loud material alike without
/// a volume calibration. The aura is a continuous bass-energy envelope (punchy material reads as
/// beats, sparse material as a gentle swell) with an onset detector that snaps it to full on
/// clear bass hits.
final class SpectrumAnalyzer {
    static let bandCount = 6

    private let fftSize = 2048
    private let hopSize = 1024
    private let log2n = vDSP_Length(11)

    private let fftSetup: FFTSetup
    private var window: [Float]

    /// Ring of the most recent mono samples (`fftSize` capacity is all the FFT ever looks at).
    private var ring: [Float]
    private var ringWrite = 0
    private var totalSamples = 0
    private var samplesSinceHop = 0

    // Scratch buffers, allocated once.
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]

    private var sampleRate = 48000.0
    /// FFT bin index ranges per equalizer band, derived from `bandEdgesHz` at `prepare`.
    private var bandBins: [Range<Int>] = []
    /// Band boundaries in Hz — log-spaced across the musically active range.
    private let bandEdgesHz: [Double] = [45, 120, 300, 750, 1900, 4800, 12000]
    /// Bin range for the bass band that drives the aura.
    private var bassBins = 1..<2

    // Per-band adaptive normalization + display smoothing.
    private var bandPeaks = [Float](repeating: 1e-9, count: SpectrumAnalyzer.bandCount)
    private var smoothedBars = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    // Beat/aura state.
    private var bassPeak: Float = 1e-9
    private var previousBassNorm: Float = 0
    private var fluxHistory = [Float](repeating: 0, count: 43)
    private var fluxIndex = 0
    private var envelope: Float = 0
    private var lastOnsetAt = 0.0

    init?() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Configure for the tap's stream format and reset all adaptive state.
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate > 1000 ? sampleRate : 48000
        let hzPerBin = self.sampleRate / Double(fftSize)
        let maxBin = fftSize / 2

        bandBins = (0..<Self.bandCount).map { band in
            let lo = max(1, min(maxBin - 1, Int(bandEdgesHz[band] / hzPerBin)))
            let hi = max(lo + 1, min(maxBin, Int(bandEdgesHz[band + 1] / hzPerBin)))
            return lo..<hi
        }
        let bassLo = max(1, Int(30.0 / hzPerBin))
        let bassHi = max(bassLo + 1, min(maxBin, Int(160.0 / hzPerBin)))
        bassBins = bassLo..<bassHi

        ring = [Float](repeating: 0, count: fftSize)
        ringWrite = 0
        totalSamples = 0
        samplesSinceHop = 0
        bandPeaks = [Float](repeating: 1e-9, count: Self.bandCount)
        smoothedBars = [Float](repeating: 0, count: Self.bandCount)
        bassPeak = 1e-9
        previousBassNorm = 0
        fluxHistory = [Float](repeating: 0, count: fluxHistory.count)
        fluxIndex = 0
        envelope = 0
        lastOnsetAt = 0
    }

    /// Append mono samples; when a hop completes, run one FFT and return the fresh frame.
    /// `now` is a monotonic timestamp (seconds) used for the onset refractory window.
    func process(mono: UnsafePointer<Float>, count: Int, now: Double) -> (bars: [Float], aura: Float)? {
        guard count > 0 else { return nil }
        for i in 0..<count {
            ring[ringWrite] = mono[i]
            ringWrite = (ringWrite + 1) % fftSize
        }
        totalSamples += count
        samplesSinceHop += count
        guard totalSamples >= fftSize, samplesSinceHop >= hopSize else { return nil }
        samplesSinceHop = 0
        return analyze(now: now)
    }

    // MARK: - Analysis

    private func analyze(now: Double) -> (bars: [Float], aura: Float) {
        // Unroll the ring (oldest → newest) and apply the Hann window.
        let start = ringWrite  // oldest sample position
        let tail = fftSize - start
        windowed.withUnsafeMutableBufferPointer { out in
            ring.withUnsafeBufferPointer { src in
                out.baseAddress!.update(from: src.baseAddress! + start, count: tail)
                if start > 0 {
                    (out.baseAddress! + tail).update(from: src.baseAddress!, count: start)
                }
            }
        }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Real FFT → power spectrum.
        let halfSize = fftSize / 2
        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { inBuf in
                    inBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfSize))
            }
        }

        let bars = updateBars()
        let aura = updateAura(now: now)
        return (bars, aura)
    }

    /// Per-band mean power, normalized against the band's own decaying peak, softened with a
    /// perceptual curve and attack/release smoothing.
    private func updateBars() -> [Float] {
        var bandPower = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            bandPower[band] = meanPower(in: bandBins[band])
        }
        // A shared noise floor keeps near-silent bands from normalizing hiss up to full height.
        let loudest = bandPower.max() ?? 0

        for band in 0..<Self.bandCount {
            bandPeaks[band] = max(bandPower[band], bandPeaks[band] * 0.996)
            let reference = max(bandPeaks[band], loudest * 0.005, 1e-9)
            let norm = min(1, bandPower[band] / reference)
            let target = pow(norm, 0.65)
            let current = smoothedBars[band]
            let rate: Float = target > current ? 0.55 : 0.22
            smoothedBars[band] = current + (target - current) * rate
        }
        return smoothedBars
    }

    /// Continuous bass-energy envelope with an onset detector: spectral flux of the normalized
    /// bass power against an adaptive (mean + 1.5σ) threshold, 120 ms refractory. Onsets snap
    /// the envelope to full; between onsets it decays toward the running bass level.
    private func updateAura(now: Double) -> Float {
        let bass = meanPower(in: bassBins)
        bassPeak = max(bass, bassPeak * 0.996)
        let bassNorm = min(1, bass / max(bassPeak, 1e-9))

        let flux = max(0, bassNorm - previousBassNorm)
        previousBassNorm = bassNorm

        var mean: Float = 0
        for value in fluxHistory { mean += value }
        mean /= Float(fluxHistory.count)
        var variance: Float = 0
        for value in fluxHistory { variance += (value - mean) * (value - mean) }
        let std = sqrt(variance / Float(fluxHistory.count))
        fluxHistory[fluxIndex] = flux
        fluxIndex = (fluxIndex + 1) % fluxHistory.count

        let isOnset = flux > mean + 1.5 * std && flux > 0.08 && now - lastOnsetAt > 0.12
        if isOnset { lastOnsetAt = now }

        // ~21 ms per hop at 48 kHz; exp(-hop/0.25s) ≈ 0.918 per-hop decay.
        let dt = Float(hopSize) / Float(sampleRate)
        let decay = exp(-dt / 0.25)
        envelope = isOnset ? 1.0 : max(envelope * decay, bassNorm * 0.6)
        return envelope
    }

    private func meanPower(in bins: Range<Int>) -> Float {
        var sum: Float = 0
        for bin in bins { sum += power[bin] }
        return sum / Float(bins.count)
    }
}
