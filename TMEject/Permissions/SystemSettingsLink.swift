import Foundation

/// Apple's documented `x-apple.systempreferences:` URL prefixes for jumping the user straight
/// to a specific Privacy & Security pane. Cheaper than walking them through the click path.
enum SystemSettingsLink {
    /// Privacy & Security → Full Disk Access. Required for `tmutil latestbackup`,
    /// `tmutil listbackups`, and reading the contents of a mounted TM volume (which the
    /// `lsof` diagnostic depends on — without FDA, lsof against the TM volume returns
    /// empty even when holders are blocking eject).
    static let fullDiskAccess = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!

    /// Privacy & Security → Files & Folders → Removable Volumes. NOT currently required
    /// (FDA is the umbrella permission), but linked for completeness.
    static let removableVolumes = URL(string:
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_RemovableVolumes")!

    /// Privacy & Security → Accessibility. NOT currently required by TMEject — the
    /// KeyboardShortcuts library uses Carbon's RegisterEventHotKey which is permission-free.
    /// Provided as a fallback link in case an audit on a future macOS release flips that.
    static let accessibility = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
