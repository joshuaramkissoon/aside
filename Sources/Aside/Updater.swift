import AppKit
import Sparkle

/// Sparkle auto-update for release builds. Only a build whose Info.plist carries SUFeedURL and SUPublicEDKey
/// (scripts/release.sh adds them) checks for updates; local builds from scripts/build.sh never do.
/// Checks daily, then downloads and installs in the background, so new versions arrive without reinstalling.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// Whether this build updates itself (a release build with a feed and a signing key).
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil

    private var controller: SPUStandardUpdaterController?

    func start() {
        guard Self.enabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = 24 * 60 * 60
        controller.startUpdater()
        self.controller = controller
    }

    /// "Check for Updates…": Aside is a menu bar app, so come to the front first or Sparkle's window opens behind.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { Task { @MainActor in NSApp.activate() } }
    }
}
