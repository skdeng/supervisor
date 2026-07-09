import CoreAudio
import Foundation

/// Captures the system audio output through a CoreAudio process tap and streams FFT analysis
/// frames into `SpectrumFeed`.
///
/// Pipeline: a global process tap (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])` —
/// everything that plays, pre-mixdown, independent of the output device) is attached as the tap
/// sub-device of a private aggregate device whose main sub-device is the current default output;
/// an IO proc on that aggregate receives the tapped PCM and hands it to `SpectrumAnalyzer`.
///
/// Creating the tap triggers macOS's one-time "System Audio Recording Only" permission prompt
/// (`NSAudioCaptureUsageDescription`), and macOS draws its recording indicator in the menu bar
/// while the tap runs — the tap therefore runs only while music actually plays.
///
/// Hardening (both are known, reproducible failure modes of the tap stack, not paranoia):
/// - **Zero-buffer stall**: after output sample-rate renegotiation or AirPods sleep/wake the tap
///   can keep running while delivering only zeros; the sole reliable recovery is a full teardown
///   and rebuild of the tap *and* the aggregate. A watchdog rebuilds when the stream stays
///   silent for several seconds while the caller says audio should be flowing
///   (`setExpectingAudio`).
/// - **Route/rate changes**: switching the default output device (or its nominal sample rate)
///   invalidates the aggregate's main sub-device; listeners proactively rebuild.
///
/// Threading: all control-plane state is confined to `controlQueue`; PCM arrives on a dedicated
/// IO queue and touches only the analyzer and `SpectrumFeed` (which is lock-protected).
/// State changes are reported on the main actor via `onStateChange`.
final class SystemAudioTap: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case running
        /// Tap creation failed — permission denied or the tap stack is broken. No retries until
        /// `resetAvailability()` (wired to the user re-enabling the feature).
        case unavailable
    }

    /// Delivered on the main actor whenever the tap starts, stops, or becomes unavailable.
    /// Set before the first `start()`; not mutated while the tap runs.
    var onStateChange: (@MainActor @Sendable (State) -> Void)?

    private let controlQueue = DispatchQueue(label: "com.supervisor.audiotap.control")
    private let ioQueue = DispatchQueue(label: "com.supervisor.audiotap.io", qos: .userInteractive)

    // Control-plane state — controlQueue only. The analyzer is deliberately NOT stored here:
    // it is captured strongly by the IO block at proc creation, so the IO queue never reads a
    // reference the control queue could concurrently rewrite during a stop/rebuild.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var unavailable = false
    private var expectingAudio = false
    private var watchdog: DispatchSourceTimer?
    private var lastRebuildAt = 0.0
    private var rebuildScheduled = false
    private var routeListeners: [AudioPropertyListener] = []

    /// Written by the IO queue, read by the watchdog on the control queue.
    private let audibleLock = NSLock()
    private var lastAudibleAt = 0.0

    /// Mono mix scratch for the IO proc (IO queue only).
    private var monoScratch = [Float](repeating: 0, count: 8192)

    // MARK: - Public control (thread-safe, async onto the control queue)

    /// Start capturing. No-op while already running or after a failure (`.unavailable`).
    func start() {
        controlQueue.async { self.startLocked() }
    }

    /// Stop capturing and tear the tap/aggregate down (removes the recording indicator).
    func stop() {
        controlQueue.async { self.stopLocked(notify: true) }
    }

    /// Whether the caller believes audio should currently be flowing (e.g. a track is playing).
    /// The zero-buffer watchdog only rebuilds while this is true — silence while paused is normal.
    func setExpectingAudio(_ expecting: Bool) {
        controlQueue.async { self.expectingAudio = expecting }
    }

    /// Clear the `.unavailable` latch so the next `start()` attempts tap creation again.
    func resetAvailability() {
        controlQueue.async { self.unavailable = false }
    }

    // MARK: - Lifecycle (control queue)

    private func startLocked() {
        guard !running, !unavailable else { return }

        // 1. The tap: everything that plays, minus nothing.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "SuperVisor Spectrum"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        // First-ever call triggers the System Audio Recording permission prompt (the call blocks
        // until answered — we are on our own queue, so nothing user-visible stalls).
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            NSLog("SystemAudioTap: tap creation failed (%d) — permission denied or tap unavailable", tapStatus)
            unavailable = true
            notifyState(.unavailable)
            return
        }
        tapID = newTap

        // 2. A private aggregate: default output as main sub-device, our tap as tap sub-device.
        guard let output = defaultOutputDevice(), let outputUID = deviceUID(of: output) else {
            NSLog("SystemAudioTap: no default output device — cannot host the tap")
            destroyObjectsLocked()
            unavailable = true
            notifyState(.unavailable)
            return
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SuperVisor Spectrum",
            kAudioAggregateDeviceUIDKey: "com.supervisor.spectrum." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            // The tap must be a SUB-tap of an aggregate whose main sub-device is a real output —
            // a tap as the main sub-device silently yields all-zero buffers.
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != kAudioObjectUnknown else {
            NSLog("SystemAudioTap: aggregate creation failed (%d)", aggregateStatus)
            destroyObjectsLocked()
            unavailable = true
            notifyState(.unavailable)
            return
        }
        aggregateID = newAggregate

        // 3. Analyzer sized to the tap's stream format. Taps deliver linear-PCM float32; if a
        // format read ever contradicts that, bail rather than silently mis-analyze the bytes.
        let format = tapStreamFormat()
        if let format,
           format.mFormatID != kAudioFormatLinearPCM
            || (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0 {
            NSLog("SystemAudioTap: unexpected tap format (%u) — not float PCM", format.mFormatID)
            destroyObjectsLocked()
            unavailable = true
            notifyState(.unavailable)
            return
        }
        let deinterleaved = format.map {
            ($0.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        } ?? false
        guard let newAnalyzer = SpectrumAnalyzer() else {
            destroyObjectsLocked()
            unavailable = true
            notifyState(.unavailable)
            return
        }
        newAnalyzer.prepare(sampleRate: format?.mSampleRate ?? 48000)

        // 4. IO proc on the aggregate — tapped PCM arrives as the input buffer list. The block
        // owns the analyzer outright (see the note on the control-plane state above), so a
        // concurrent stop/rebuild can never yank it out from under an in-flight callback.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            self?.handleIO(inputData, analyzer: newAnalyzer, deinterleaved: deinterleaved)
        }
        guard procStatus == noErr, let proc = newProc,
              AudioDeviceStart(aggregateID, proc) == noErr else {
            NSLog("SystemAudioTap: IO proc setup failed (%d)", procStatus)
            if let proc = newProc { AudioDeviceDestroyIOProcID(aggregateID, proc) }
            destroyObjectsLocked()
            unavailable = true
            notifyState(.unavailable)
            return
        }
        ioProcID = proc

        running = true
        markAudible()  // grace period before the watchdog may consider the stream stalled
        startWatchdogLocked()
        installRouteListenersLocked(outputDevice: output)
        notifyState(.running)
    }

    private func stopLocked(notify: Bool) {
        watchdog?.cancel()
        watchdog = nil
        for listener in routeListeners { listener.invalidate() }
        routeListeners.removeAll()
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        destroyObjectsLocked()
        let wasRunning = running
        running = false
        SpectrumFeed.shared.clear()
        if notify, wasRunning {
            notifyState(.idle)
        }
    }

    private func destroyObjectsLocked() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Full teardown + rebuild — the only reliable recovery from a zero-buffer stall, and the
    /// correct response to a default-output or sample-rate change (the aggregate's main
    /// sub-device is stale either way).
    private func rebuildLocked() {
        guard running else { return }
        lastRebuildAt = CFAbsoluteTimeGetCurrent()
        stopLocked(notify: false)
        startLocked()
        // A failed rebuild latched `.unavailable` and notified; a successful one re-notified
        // `.running`, which the main-actor side treats as idempotent.
    }

    /// Coalesce bursts of route-change notifications into one rebuild.
    private func scheduleRebuild() {
        controlQueue.async {
            guard self.running, !self.rebuildScheduled else { return }
            self.rebuildScheduled = true
            self.controlQueue.asyncAfter(deadline: .now() + 0.6) {
                self.rebuildScheduled = false
                self.rebuildLocked()
            }
        }
    }

    // MARK: - Watchdog + route listeners (control queue)

    private func startWatchdogLocked() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.expectingAudio else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.audibleLock.lock()
            let audibleAt = self.lastAudibleAt
            self.audibleLock.unlock()
            if now - audibleAt > 6, now - self.lastRebuildAt > 10 {
                NSLog("SystemAudioTap: stream silent while playing — rebuilding tap")
                self.rebuildLocked()
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func installRouteListenersLocked(outputDevice: AudioObjectID) {
        let defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let listener = AudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: defaultOutputAddress,
            onChange: { [weak self] in self?.scheduleRebuild() }
        ) {
            routeListeners.append(listener)
        }

        let sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let listener = AudioPropertyListener(
            objectID: outputDevice,
            address: sampleRateAddress,
            onChange: { [weak self] in self?.scheduleRebuild() }
        ) {
            routeListeners.append(listener)
        }
    }

    // MARK: - IO (IO queue)

    private func handleIO(
        _ bufferList: UnsafePointer<AudioBufferList>,
        analyzer: SpectrumAnalyzer,
        deinterleaved: Bool
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))

        for (index, buffer) in buffers.enumerated() {
            // Deinterleaved layout is one mono buffer per channel; the first channel alone is
            // plenty for a visualizer, and treating later ones as more time samples would
            // corrupt the spectrum.
            if deinterleaved && index > 0 { break }
            guard let data = buffer.mData else { continue }
            let channels = deinterleaved ? 1 : max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { continue }
            let clamped = min(frames, monoScratch.count)
            let samples = data.assumingMemoryBound(to: Float32.self)

            // Float32 → mono mix, tracking energy for the stall watchdog.
            var sumSquares: Float = 0
            monoScratch.withUnsafeMutableBufferPointer { mono in
                for frame in 0..<clamped {
                    var mixed: Float = 0
                    let base = frame * channels
                    for channel in 0..<channels {
                        mixed += samples[base + channel]
                    }
                    mixed /= Float(channels)
                    mono[frame] = mixed
                    sumSquares += mixed * mixed
                }
            }
            // The stall mode delivers EXACT zeros; genuinely quiet music still carries
            // tiny nonzero samples. Only an all-zero buffer counts as a stall candidate,
            // so soft passages never trip the watchdog into a rebuild.
            if sumSquares > 0 {
                markAudible(at: now)
            }

            let result = monoScratch.withUnsafeBufferPointer { mono in
                analyzer.process(mono: mono.baseAddress!, count: clamped, now: now)
            }
            if let result {
                SpectrumFeed.shared.publish(bars: result.bars, aura: result.aura)
            }
        }
    }

    private func markAudible(at time: Double = CFAbsoluteTimeGetCurrent()) {
        audibleLock.lock()
        lastAudibleAt = time
        audibleLock.unlock()
    }

    // MARK: - State reporting

    private func notifyState(_ state: State) {
        guard let onStateChange else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onStateChange(state) }
        }
    }

    // MARK: - CoreAudio queries (control queue)

    private func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func deviceUID(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func tapStreamFormat() -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else { return nil }
        return format
    }
}
