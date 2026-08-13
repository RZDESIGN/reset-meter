import AppKit
import SwiftUI

@main
struct ResetMeterApp: App {
    @StateObject private var store: UsageStore

    init() {
        let snapshotPath = Self.snapshotPath
        let usageStore = UsageStore(autoRefresh: snapshotPath == nil)
        _store = StateObject(wrappedValue: usageStore)

        if let snapshotPath {
            Task { @MainActor in
                await usageStore.refresh()
                do {
                    try SnapshotWriter.write(store: usageStore, to: snapshotPath)
                } catch {
                    fputs("Snapshot failed: \(error.localizedDescription)\n", stderr)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopover(store: store)
        } label: {
            StatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }

    private static var snapshotPath: String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) else {
            return nil
        }
        return arguments[flag + 1]
    }
}

@MainActor
private enum SnapshotWriter {
    static func write(store: UsageStore, to path: String) throws {
        let popover = UsagePopover(store: store)
            .padding(18)
            .background(Color(nsColor: .windowBackgroundColor))
        try writePNG(popover, to: URL(fileURLWithPath: path))

        let outputURL = URL(fileURLWithPath: path)
        let menuURL = outputURL.deletingLastPathComponent()
            .appending(path: outputURL.deletingPathExtension().lastPathComponent + "-menu.png")
        let menuLabel = StatusLabel(store: store)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundStyle(Color.white)
            .background(Color.black.opacity(0.82))
            .environment(\.colorScheme, .dark)
        try writePNG(menuLabel, to: menuURL)
    }

    private static func writePNG<Content: View>(_ content: Content, to url: URL) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try png.write(to: url, options: .atomic)
    }
}
