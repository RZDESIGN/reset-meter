import AppKit
import SwiftUI
import UsageMeterCore

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
                    usageStore.loadDemoData(multipleAccounts: CommandLine.arguments.contains("--demo-multiple-accounts"))
                } else {
                    await usageStore.refresh()
                }
                do {
                    try await SnapshotWriter.write(store: usageStore, to: outputPath)
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
    static func write(store: UsageStore, to path: String) async throws {
        let popover = UsagePopover(store: store)
            .padding(18)
            .background(Color(nsColor: .windowBackgroundColor))
        try await writePNG(popover, to: URL(fileURLWithPath: path))

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
        try await writePNG(menuLabel, to: menuURL)
        let accountsURL = outputURL.deletingLastPathComponent()
            .appending(path: outputURL.deletingPathExtension().lastPathComponent + "-accounts.png")
        try await writePNG(AccountSettings(store: store)
            .frame(width: 520, height: 720)
            .background(Color(nsColor: .windowBackgroundColor)), to: accountsURL)
        for provider in [UsageProvider.claude, .cursor] {
            let providerURL = outputURL.deletingLastPathComponent()
                .appending(path: outputURL.deletingPathExtension().lastPathComponent + "-\(provider.rawValue).png")
            try await writePNG(AccountSettings(store: store, selectedProvider: provider)
                .frame(width: 520, height: 720)
                .background(Color(nsColor: .windowBackgroundColor)), to: providerURL)
        }
    }

    private static func writePNG<Content: View>(_ content: Content, to url: URL) async throws {
        // Render through AppKit so native scroll views are included in snapshots.
        let view = NSHostingView(rootView: content)
        var size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view

        // The popover measures its own cards, so its first proposal can exceed
        // the settled height. Re-layout until the size stops changing, or the
        // capture keeps the taller frame and pads the image with blank space.
        for _ in 0..<5 {
            view.frame = NSRect(origin: .zero, size: size)
            window.setContentSize(size)
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
            let settled = view.fittingSize
            if settled == size { break }
            size = settled
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try png.write(to: url, options: .atomic)
    }
}
