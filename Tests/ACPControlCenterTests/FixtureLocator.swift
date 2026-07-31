import Foundation

/// Resolves fixture URLs from either SwiftPM's generated resource bundle or
/// the Xcode unit-test bundle used by `ACPControlCenter.xcodeproj`.
enum FixtureLocator {
    private final class TestBundleToken {}

    static func url(_ relativePath: String) -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            fatalError("Invalid fixture path: \(relativePath)")
        }
        let subdirectoryComponents = ["Fixtures"] + components.dropLast()
        let subdirectory = subdirectoryComponents.joined(separator: "/")

        let nameAndExtension = fileName.split(separator: ".", maxSplits: 1)
        let name = String(nameAndExtension[0])
        let extension_ = nameAndExtension.count > 1 ? String(nameAndExtension[1]) : nil

        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: TestBundleToken.self)
        #endif

        guard let url = resourceBundle.url(
            forResource: name,
            withExtension: extension_,
            subdirectory: subdirectory
        ) else {
            fatalError("Fixture not found: \(relativePath) (looked in \(subdirectory))")
        }
        return url
    }
}
