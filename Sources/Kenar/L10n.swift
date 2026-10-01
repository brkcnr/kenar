import Foundation

/// Localized string lookup. Keys include retained Brink English keys and Kenar
/// Turkish UI keys; translations live in
/// `Resources/<lang>.lproj/Localizable.strings`.
///
/// Turkish is the default. Users can choose Turkish or English in Settings.
enum L10n {
    private static let lock = NSRecursiveLock()
    private static var languageCode = "tr"

    /// Where Kenar's resources (logos, .lproj folders) live.
    ///
    /// In the packaged app `build.sh` copies them into `Contents/Resources`, so
    /// `Bundle.main` serves them the standard macOS way. Only when running straight
    /// from `swift build` (no .app) do we fall back to SwiftPM's `Bundle.module`.
    /// Never touch `Bundle.module` first: its accessor only knows the build-machine
    /// path and the .app root, and crashes on any other Mac (issue #8).
    static let resources: Bundle = {
        if Bundle.main.url(forResource: "claude", withExtension: "png") != nil { return Bundle.main }
        return Bundle.module
    }()

    /// The persisted selection is owned by Settings; localization is thread-safe
    /// because provider requests also create messages off the main thread.
    static var override: String {
        get { lock.lock(); defer { lock.unlock() }; return languageCode }
        set { lock.lock(); defer { lock.unlock() }; languageCode = newValue == "en" ? "en" : "tr"; cachedBundle = nil }
    }

    private static var cachedBundle: Bundle?

    /// Bundle to read strings from: the chosen language's .lproj, or the module
    /// bundle (which follows the system language) when no override is set.
    static var bundle: Bundle {
        lock.lock(); defer { lock.unlock() }
        if let cachedBundle { return cachedBundle }
        let code = override
        let b: Bundle
        // SwiftPM lower-cases .lproj folder names (zh-Hans → zh-hans); try both.
        if !code.isEmpty,
           let path = resources.path(forResource: code, ofType: "lproj")
                   ?? resources.path(forResource: code.lowercased(), ofType: "lproj"),
           let lb = Bundle(path: path) {
            b = lb
        } else {
            b = resources
        }
        cachedBundle = b
        return b
    }
}

func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, tableName: nil, bundle: L10n.bundle, value: key, comment: "")
    return args.isEmpty ? format : String(format: format, locale: DisplayFormat.locale, arguments: args)
}

extension String {
    /// "Resets in 5 min" → "resets in 5 min" (used mid-sentence in notifications).
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
