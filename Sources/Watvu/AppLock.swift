import Foundation
import LocalAuthentication

/// Whole-app lock: biometric (Touch ID) when available, else the app PIN.
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var enabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @Published var locked = false

    private init() {
        locked = enabled
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "appLockEnabled")
        enabled = on
        locked = on
    }

    func unlockWithBiometrics() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            locked = false   // no biometrics enrolled — fall back to PIN gate
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: NSLocalizedString("Unlock Watvu", comment: "")) { ok, _ in
            DispatchQueue.main.async { if ok { self.locked = false } }
        }
    }

    func unlockWithPIN(_ pin: String, model: AppModel) -> Bool {
        let ok = MainActor.assumeIsolated { model.verifyPIN(pin) }
        guard ok else { return false }
        locked = false
        return true
    }
}
