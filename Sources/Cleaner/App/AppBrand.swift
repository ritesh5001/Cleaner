import AppKit

@MainActor
enum AppBrand {
    private static let resources = Bundle.main.url(forResource: "StorageFusion_StorageFusion", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? Bundle.module

    static let icon = loadImage(named: "AppIcon")

    static let menuBarIcon: NSImage = {
        let image = loadImage(named: "MenuBarIcon")
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Storage Fusion"
        return image
    }()

    private static func loadImage(named name: String) -> NSImage {
        resources.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage()
    }
}
