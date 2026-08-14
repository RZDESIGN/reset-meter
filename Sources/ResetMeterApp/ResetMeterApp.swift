import AppKit
import SwiftUI

@main
struct ResetMeterApp: App {
    @StateObject private var store: UsageStore

    init() {
        let snapshotPath = Self.snapshotPath
        let demoSnapshotPath = Self.demoSnapshotPath
        let outputPath = demoSnapshotPath ?? snapshotPath
        let usageStore = UsageStore(autoRefresh: outputPath == nil)
        _store = StateObject(wrappedValue: usageStore)

        if let outputPath {
            Task { @MainActor in
                if demoSnapshotPath != nil {
                    usageStore.loadDemoData()
                } else {
                    await usageStore.refresh()
                }
                do {
                    try SnapshotWriter.write(store: usageStore, to: outputPath)
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
        argument(after: "--snapshot")
    }

    private static var demoSnapshotPath: String? {
        argument(after: "--snapshot-demo")
    }

    private static func argument(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
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
        let menuLabel = HStack(spacing: 0) {
            Spacer(minLength: 24)
            StatusLabel(store: store)
            Spacer(minLength: 24)
        }
            .frame(width: 640, height: 32)
            .foregroundStyle(Color.white)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.07, blue: 0.24),
                        Color(red: 0.08, green: 0.34, blue: 0.45),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 0.5)
            }
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
