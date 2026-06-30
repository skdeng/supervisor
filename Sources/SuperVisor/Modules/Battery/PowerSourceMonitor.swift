import Foundation
import IOKit.ps

/// Reads internal-battery state from IOKit's IOPowerSources API and delivers live updates by
/// installing an `IOPSNotificationCreateRunLoopSource` on the main run loop.
///
/// All snapshot reads (`IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription`) are
/// cheap and safe to call from the notification callback. The callback is a C function, so it
/// recovers `self` from an opaque context pointer and invokes the stored Swift closure.
final class PowerSourceMonitor {
    /// Invoked whenever power-source state changes (and once at start). Always called on the
    /// thread that owns the run loop the source was added to — here, the main thread.
    var onChange: ((BatteryState) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    /// Begin observing. Installs the run-loop source and fires an initial snapshot.
    func start() {
        // Pass an unretained pointer to self; the source lives as long as this object.
        let context = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.emit()
        }

        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Initial snapshot so callers don't wait for the first system change.
        emit()
    }

    /// Tear down the run-loop source.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        onChange = nil
    }

    deinit {
        // Safety net: the run-loop source carries an unretained pointer to `self`, so it must
        // never outlive this object. `stop()` is the normal teardown path, but if the monitor
        // is released without it (e.g. an unexpected ownership change), remove the source here
        // so a later power-source change can't fire the C callback into freed memory.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    /// Read the current snapshot and deliver it.
    private func emit() {
        onChange?(Self.currentState())
    }

    /// Compute a `BatteryState` from the current IOPowerSources snapshot. Static and
    /// self-contained so it can be called from anywhere without retaining the monitor.
    static func currentState() -> BatteryState {
        var state = BatteryState()

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return state
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }

            // Only consider the internal battery power source.
            let type = desc[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }

            state.isPresent = true

            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let capacity = desc[kIOPSMaxCapacityKey] as? Int, capacity > 0 {
                state.fraction = min(1.0, max(0.0, Double(current) / Double(capacity)))
            }

            let powerState = desc[kIOPSPowerSourceStateKey] as? String
            state.isPluggedIn = (powerState == kIOPSACPowerValue)

            state.isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            state.isCharged = (desc[kIOPSIsChargedKey] as? Bool) ?? false

            // Time-to-empty / time-to-full. IOKit reports minutes; -1 means "still
            // calculating", 0 can mean charged. Convert to seconds and drop non-positive.
            if state.isPluggedIn {
                if let toFull = desc[kIOPSTimeToFullChargeKey] as? Int, toFull > 0 {
                    state.secondsRemaining = toFull * 60
                }
            } else {
                if let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int, toEmpty > 0 {
                    state.secondsRemaining = toEmpty * 60
                }
            }

            break
        }

        return state
    }
}
