import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Configuration lives in Info.plist:
///   - SUFeedURL → https://d4g4.github.io/TMEject/appcast.xml
///   - SUPublicEDKey → public half of the EdDSA pair (private key stays in keychain — generated
///     once via `generate_keys` from the Sparkle CLI; see docs/release-setup.md)
///   - SUEnableAutomaticChecks → YES
///   - SUScheduledCheckInterval → 86400 (24h)
///
/// Beta channel: Sparkle 2 uses `<sparkle:channel>` item attributes — items with no channel tag
/// are stable, items with `beta` are gated behind `allowedChannels(for:)`. The toggle in
/// About/Settings flips `SettingsKey.betaChannel`; we read it fresh on every call so a toggle
/// change takes effect on the next check without restarting the app.
@MainActor
final class TMEjectUpdater: NSObject {
    static let shared = TMEjectUpdater()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// User-initiated check. Surfaces the standard Sparkle UI for both "up to date" and
    /// "update available."
    func checkForUpdates() {
        UIActionLogger.buttonTapped("Check for Updates", context: "TMEjectUpdater")
        controller.checkForUpdates(nil)
    }

    /// Sparkle's SPUStandardUpdaterController doesn't check on launch by default — it waits
    /// out the full SUScheduledCheckInterval (24h) from the previous check. For a menu-bar
    /// app that's relaunched after sleep/reboot/quit, the natural UX is "check shortly after
    /// I launch you." 15s delay so the launch HUD + notification ask + initial network init
    /// finish first.
    func checkForUpdatesInBackgroundAfterLaunchSettle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            TMEjectLog.app.info("Background update check (post-launch settle)")
            self?.controller.updater.checkForUpdatesInBackground()
        }
    }
}

extension TMEjectUpdater: SPUUpdaterDelegate {
    /// Returns the additional channels this install accepts items from. Stable users see
    /// stable items only. Beta users see stable + beta (channel filtering is additive).
    /// Read fresh from UserDefaults every call.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let enabled = UserDefaults.standard.bool(forKey: SettingsKey.betaChannel)
        return enabled ? ["beta"] : []
    }
}
