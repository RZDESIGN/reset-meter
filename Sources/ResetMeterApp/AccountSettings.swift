import AppKit
import SwiftUI
import UsageMeterCore

@MainActor
enum AccountWindow {
    private static var window: NSWindow?

    static func show(store: UsageStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.title = "Providers & Accounts"
            window.contentMinSize = NSSize(width: 500, height: 560)
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
    @State private var newName = ""
    @State private var newAccountProvider: UsageProvider = .codex
    @State private var newMode: ConnectionMode = .login
    @State var selectedProvider: UsageProvider? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Providers & accounts")
                    .font(.title2.bold())
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh usage")
                    .disabled(store.signingInAccountID != nil)
                }
            }
            Text("Show or hide each meter in the menu bar and popover. Hidden meters stay here with their usage details.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $selectedProvider) {
                Text("All").tag(nil as UsageProvider?)
                Text("Codex").tag(UsageProvider.codex as UsageProvider?)
                Text("Claude").tag(UsageProvider.claude as UsageProvider?)
                Text("Cursor").tag(UsageProvider.cursor as UsageProvider?)
            }
            .pickerStyle(.segmented)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.entries.filter { selectedProvider == nil || $0.provider == selectedProvider }) { entry in
                        ProviderCard(
                            entry: entry,
                            visibility: Binding(
                                get: { store.isVisible(entry.id) },
                                set: { store.setVisible($0, entryID: entry.id) }
                            ),
                            showsAccountName: false
                        ) {
                            AccountControls(store: store, entry: entry)
                        }
                    }
                }
                .padding(2)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            Text("Add \(addingProvider.displayName) account").font(.headline)
            HStack {
                if selectedProvider == nil {
                    Picker("Account provider", selection: $newAccountProvider) {
                        Text("Codex").tag(UsageProvider.codex)
                        Text("Claude").tag(UsageProvider.claude)
                        Text("Cursor").tag(UsageProvider.cursor)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(busy)
                }
                Picker("Connection", selection: $newMode) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
            }
            HStack {
                TextField("Account name, e.g. Work", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAccount() }
                Button(newMode == .login ? "Add & Sign In" : "Add Local") { addAccount() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
            Text(newMode == .login
                 ? "Sign in in your browser. Each Login connection stays separate from your installed app and other accounts."
                 : "Uses the account already signed in on this Mac. Local connections to the same provider share that account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.signingInAccountID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Complete sign-in in your browser…").font(.caption)
                    Spacer()
                    Button("Cancel") { store.cancelSignIn() }
                }
            }
            if let error = store.accountError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 520, maxWidth: .infinity,
               minHeight: 560, idealHeight: 720, maxHeight: .infinity)
    }

    private var busy: Bool { store.isRefreshing || store.signingInAccountID != nil }
    private var addingProvider: UsageProvider { selectedProvider ?? newAccountProvider }

    private func addAccount() {
        guard !busy, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addAccount(name: newName, provider: addingProvider, mode: newMode)
        newName = ""
    }
}

private struct AccountControls: View {
    @ObservedObject var store: UsageStore
    let entry: UsageEntry
    @State private var name: String

    init(store: UsageStore, entry: UsageEntry) {
        self.store = store
        self.entry = entry
        _name = State(initialValue: entry.accountName ?? "Default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Connection", selection: Binding(
                get: { entry.mode },
                set: { mode in
                    store.setMode(mode, entryID: entry.id)
                    Task { await store.refresh() }
                }
            )) {
                ForEach(ConnectionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            .accessibilityLabel("\(entry.provider.displayName) \(name) connection mode")
            HStack {
                TextField("Account name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, value in
                        if let account = entry.account { store.renameAccount(account, name: value) }
                        if let account = entry.claudeAccount { store.renameAccount(account, name: value) }
                        if let account = entry.cursorAccount { store.renameAccount(account, name: value) }
                    }
                if entry.mode == .login {
                    Button("Sign In") {
                        if let account = entry.account { store.signIn(account) }
                        if let account = entry.claudeAccount { store.signIn(account) }
                        if let account = entry.cursorAccount { store.signIn(account) }
                    }
                    .disabled(busy)
                }
                if !isDefault {
                    Button(role: .destructive) {
                        if let account = entry.account { store.removeAccount(account) }
                        if let account = entry.claudeAccount { store.removeAccount(account) }
                        if let account = entry.cursorAccount { store.removeAccount(account) }
                    } label: { Image(systemName: "trash") }
                    .disabled(busy)
                    .help("Remove this account and its saved Reset Meter login")
                    .accessibilityLabel("Remove \(entry.provider.displayName) \(name)")
                }
            }
            Text(connectionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isDefault: Bool {
        entry.account?.isDefault ?? entry.claudeAccount?.isDefault ?? entry.cursorAccount?.isDefault ?? true
    }

    private var connectionDescription: String {
        if entry.mode == .login {
            return entry.provider == .claude
                ? "Separate browser login for live account usage and reset times. Uses the sign-in helper built into the Claude app."
                : "Separate browser login saved for this Reset Meter account."
        }
        switch entry.provider {
        case .codex: return "Uses the current Codex app or CLI login on this Mac."
        case .claude: return "Reads the Claude app’s usage cache, which has no reset times, or a current Claude Code login. Never changes either."
        case .cursor: return "Uses the current Cursor app login on this Mac."
        }
    }

    private var busy: Bool { store.isRefreshing || store.signingInAccountID != nil }
}
