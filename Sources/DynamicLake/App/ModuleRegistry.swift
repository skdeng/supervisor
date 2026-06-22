import Foundation

/// THE single integration point. The integration phase fills in `allModules()`.
/// Foundation leaves it returning []. Order in the array is irrelevant (modules
/// sort themselves via `order`).
@MainActor
enum ModuleRegistry {
    static func allModules() -> [any NotchModule] {
        [
            MediaModule(),
            FileShelfModule(),
            BatteryModule(),
        ]
    }
}
