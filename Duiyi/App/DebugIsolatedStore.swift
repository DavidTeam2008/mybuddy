#if DEBUG
import Foundation

/// Redirects the app to a throwaway SwiftData store so on-device UI tests can
/// seed and delete tasks without touching the developer's real history.
///
/// Launch with `-duiyi.storeFile <file-name>`. Debug builds only.
enum DebugIsolatedStore {
    static var storeURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-duiyi.storeFile") else { return nil }
        let nameIndex = arguments.index(after: flag)
        guard nameIndex < arguments.endIndex else { return nil }
        let name = arguments[nameIndex]
        guard !name.isEmpty else { return nil }

        let directory = URL.applicationSupportDirectory
            .appending(path: "UITestStores", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(name).store")
    }
}
#endif
