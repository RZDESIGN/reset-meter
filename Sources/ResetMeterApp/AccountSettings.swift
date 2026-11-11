import AppKit
import SwiftUI
import UsageMeterCore

@MainActor
enum AccountWindow {
    private static var window: NSWindow?

    static func show(store: UsageStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Providers & Local Accounts"
            window.contentMinSize = NSSize(width: 520, height: 580)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AccountSettings(store: store))
            window.center()
            Self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AccountSettings: View {
    @ObservedObject var store: UsageStore
    @State var selectedProvider: UsageProvider? = nil
    @State private var newName = ""
    @State private var newProvider: UsageProvider = .codex
    @State private var newProfilePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            Text("Reset Meter reads your installed AI clients locally in read-only mode — no extra sign-ins or Keychain prompts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text("Menu bar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Menu bar style", selection: $store.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 240)
                Spacer()
            }

            Picker("Provider", selection: $selectedProvider) {
                Text("All").tag(nil as UsageProvider?)
                ForEach(UsageProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider as UsageProvider?)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(filteredEntries) { entry in
                        ProviderCard(
                            entry: entry,
                            visibility: Binding(
                                get: { store.isVisible(entry.id) },
                                set: { store.setVisible($0, entryID: entry.id) }
                            ),
                            showsAccountSubtitle: false
                        ) {
                            AccountControls(store: store, entry: entry)
                        }
                    }
                }
                .padding(2)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            customProfileSection
        }
        .padding(20)
        .frame(
            minWidth: 520, idealWidth: 560, maxWidth: .infinity,
            minHeight: 580, idealHeight: 740, maxHeight: .infinity
        )
    }

    private var filteredEntries: [UsageEntry] {
        store.entries.filter { selectedProvider == nil || $0.provider == selectedProvider }
    }

    private var addingProvider: UsageProvider {
        selectedProvider ?? newProvider
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Providers & local accounts")
                .font(.title2.bold())
            Spacer()
            Button {
                store.rescanLocalInstallations()
            } label: {
                Label("Scan Local Apps", systemImage: "sparkle.magnifyingglass")
                    .font(.caption.weight(.medium))
            }
            .controlSize(.small)
            .disabled(store.isRefreshing)
            .help("Detect separate local Claude, ChatGPT / Codex, Antigravity, and Cursor installations")

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh usage")
            }
        }
    }

    private var customProfileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add custom local profile")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 8) {
                if selectedProvider == nil {
                    Picker("Provider", selection: $newProvider) {
                        ForEach(UsageProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(store.isRefreshing)
                }

                TextField("Label (e.g. Work)", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                TextField("Folder path", text: $newProfilePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCustomAccount() }

                Button("Browse…") {
                    chooseFolder()
                }
                .disabled(store.isRefreshing)

                Button("Add") {
                    addCustomAccount()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddCustomAccount || store.isRefreshing)
            }

            Text(addingProvider.localSourceHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var canAddCustomAccount: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newProfilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addCustomAccount() {
        guard canAddCustomAccount else { return }
        store.addLocalAccount(
            name: newName,
            provider: addingProvider,
            profilePath: newProfilePath
        )
        newName = ""
        newProfilePath = ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Select Profile"
        panel.message = "Choose the local profile folder for \(addingProvider.displayName)"
        if panel.runModal() == .OK, let url = panel.url {
            newProfilePath = url.path
            if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newName = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
    }
}

private struct AccountControls: View {
    @ObservedObject var store: UsageStore
    let entry: UsageEntry
    @State private var name: String

    init(store: UsageStore, entry: UsageEntry) {
        self.store = store
        self.entry = entry
        _name = State(initialValue: entry.accountName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Account label", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: name) { _, value in
                        store.renameAccount(entry.account, name: value)
                    }

                Button {
                    let target = entry.account.revealDirectoryURL()
                    if FileManager.default.fileExists(atPath: target.path) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.path)
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Open local profile folder in Finder")

                if !entry.account.isDefault {
                    Button(role: .destructive) {
                        store.removeAccount(entry.account)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .disabled(store.isRefreshing)
                    .help("Remove this profile card from Reset Meter (does not touch your local client data)")
                    .accessibilityLabel("Remove \(entry.displayName)")
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                Text(entry.account.displaySourcePath())
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.tertiary)
        }
    }
}
