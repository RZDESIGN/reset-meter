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
                            if let account = entry.account {
                                AccountControls(store: store, account: account)
                            }
                        }
                    }
                }
                .padding(2)
            }
            .scrollBounceBehavior(.basedOnSize)
            if selectedProvider == nil || selectedProvider == .codex {
                Divider()
                Text("Add Codex account").font(.headline)
                HStack {
                    TextField("Account name, e.g. Work", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addAccount() }
                    Button("Add & Sign In") { addAccount() }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
                Text("Sign in with the other subscription in your browser. Each added account keeps its own local Codex login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func addAccount() {
        guard !busy, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.addAccount(name: newName)
        newName = ""
    }
}

private struct AccountControls: View {
    @ObservedObject var store: UsageStore
    let account: CodexAccount
    @State private var name: String

    init(store: UsageStore, account: CodexAccount) {
        self.store = store
        self.account = account
        _name = State(initialValue: account.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Account name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, value in store.renameAccount(account, name: value) }
                if !account.isDefault {
                    Button("Sign In") { store.signIn(account) }
                        .disabled(busy)
                    Button(role: .destructive) { store.removeAccount(account) } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(busy)
                    .help("Remove this account and its local Reset Meter login")
                }
            }
            if account.isDefault {
                Text("Uses your current Codex CLI login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var busy: Bool { store.isRefreshing || store.signingInAccountID != nil }
}
