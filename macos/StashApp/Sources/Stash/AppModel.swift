import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case starting, createVault, locked, unlocked, failed(String) }
    enum UnlockMethod: String { case touchID, password }

    private static let unlockMethodKey = "preferredUnlockMethod"

    @Published var screen: Screen = .starting
    @Published var status: VaultStatus?
    @Published var preferredUnlockMethod: UnlockMethod {
        didSet { defaults.set(preferredUnlockMethod.rawValue, forKey: Self.unlockMethodKey) }
    }
    @Published var items: [ItemSummary] = []
    @Published private(set) var groups: [VaultGroup] = [.personal]
    @Published private(set) var selectedGroupID: VaultGroup.ID?
    @Published var selection: ItemSummary.ID?
    @Published var detail: ItemDetail?
    @Published var search = ""
    @Published var error: String?
    @Published var busy = false
    /// A value briefly shown after "Copy", for the toast.
    @Published var toast: String?
    /// The open editor sheet, if any.
    @Published var editor: EditorTarget?
    /// The export file being imported, while its sheet is open.
    @Published var importFile: ImportFile?

    let backend: VaultBackend?
    private let defaults: UserDefaults
    private var starting = false

    init(backend: VaultBackend?, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
        let savedMethod = defaults.string(forKey: Self.unlockMethodKey)
        preferredUnlockMethod = savedMethod.flatMap(UnlockMethod.init(rawValue:)) ?? .touchID
    }

    var canUseTouchID: Bool {
        status?.touchIdEnabled == true && status?.touchIdAvailable == true
    }

    var effectiveUnlockMethod: UnlockMethod {
        canUseTouchID ? preferredUnlockMethod : .password
    }

    enum Filter: Hashable {
        case all
        case kind(ItemKind)
        case folder(String)

        var title: String {
            switch self {
            case .all: String(localized: "All Items")
            case .kind(let k): k.pluralTitle
            case .folder(let f): f
            }
        }
    }

    enum Sort { case name, updated }

    @Published var filter: Filter = .all
    @Published var sort: Sort = .name

    func matches(_ item: ItemSummary, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .kind(let k): item.kind == k
        case .folder(let f): item.folder?.split(separator: "/").first.map(String.init) == f
        }
    }

    /// What "New Item" preselects: the kind of category you're viewing.
    var suggestedKind: ItemKind {
        if case .kind(let k) = filter { k } else { .login }
    }

    private var scopedItems: [ItemSummary] {
        guard let selectedGroupID else { return items }
        return items.filter { $0.groupID == selectedGroupID }
    }

    var scopeTitle: String {
        guard let selectedGroupID else { return filter.title }
        let group = groupTitle(selectedGroupID)
        return filter == .all ? group : "\(group) · \(filter.title)"
    }

    var searchPrompt: String {
        if let selectedGroupID {
            return String(localized: "Search in \(groupTitle(selectedGroupID))")
        }
        return String(localized: "Search \(filter.title.lowercased())")
    }

    var suggestedGroupID: VaultGroup.ID { selectedGroupID ?? VaultGroup.personal.id }

    func groupTitle(_ id: VaultGroup.ID) -> String {
        groups.first { $0.id == id }?.title ?? VaultGroup.personal.title
    }

    func count(_ filter: Filter) -> Int { scopedItems.filter { matches($0, filter) }.count }

    func count(inGroup id: VaultGroup.ID) -> Int { items.filter { $0.groupID == id }.count }

    func selectGroup(_ id: VaultGroup.ID?) {
        selectedGroupID = id
        filter = .all
        search = ""
        selection = nil
        detail = nil
    }

    /// Top-level folders, from names like `work/github`.
    var folders: [String] {
        Array(Set(scopedItems.compactMap { $0.folder?.split(separator: "/").first.map(String.init) })).sorted()
    }

    var filtered: [ItemSummary] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = scopedItems.filter { matches($0, filter) }.filter {
            q.isEmpty
                || $0.name.lowercased().contains(q)
                || ($0.username?.lowercased().contains(q) ?? false)
                || ($0.url?.lowercased().contains(q) ?? false)
        }
        switch sort {
        // By the name shown in the table (the last segment), then by folder.
        case .name: return shown.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame
                ? ($0.folder ?? "").localizedCaseInsensitiveCompare($1.folder ?? "") == .orderedAscending
                : order == .orderedAscending
        }
        case .updated: return shown.sorted { $0.updated > $1.updated }
        }
    }

    /// In this filter's scope, before searching: for "3 of 12 items".
    var scopeCount: Int { count(filter) }

    // MARK: - Lifecycle

    func start() async {
        guard case .starting = screen, !starting else { return }
        starting = true
        defer { starting = false }
        guard let backend else {
            screen = .failed(String(localized: "Couldn't start the stash backend. Is the stash command-line tool installed?"))
            return
        }
        do {
            let s = try await backend.status()
            status = s
            if !s.vaultExists {
                screen = .createVault
            } else if s.locked {
                screen = .locked
                if effectiveUnlockMethod == .touchID { await unlockWithTouchID() }
            } else {
                await didUnlock()
            }
        } catch {
            screen = .failed(error.localizedDescription)
        }
    }

    /// Check for an idle lock and use the preferred method when the user opens stash.
    func prepareForAccess() async {
        guard !busy else { return }
        if case .starting = screen {
            await start()
            return
        }
        if case .unlocked = screen { await reload() }
        if effectiveUnlockMethod == .touchID { await unlockWithTouchID() }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            error = nil
            try await work()
        } catch let e as BackendError where e.isLocked {
            becameLocked()
        } catch let e as BackendError where e.isCancelled {
            // The user dismissed Touch ID: not an error worth shouting about.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func becameLocked() {
        items = []
        groups = [.personal]
        selectGroup(nil)
        screen = .locked
    }

    private func didUnlock() async {
        status = try? await backend?.status()
        screen = .unlocked
        await reload()
    }

    func createVault(password: String) async {
        await run {
            try await backend?.createVault(password: password)
            await didUnlock()
        }
    }

    func unlock(password: String) async {
        guard case .locked = screen, !busy, let backend else { return }
        await run {
            try await backend.unlock(password: password)
            await didUnlock()
        }
    }

    func unlockWithTouchID() async {
        guard case .locked = screen, !busy, canUseTouchID, let backend else { return }
        await run {
            try await backend.unlockWithTouchID()
            await didUnlock()
        }
    }

    func lock() async {
        await run {
            try await backend?.lock()
            becameLocked()
        }
    }

    // MARK: - Items

    private func refreshListing() async throws {
        let listing = try await backend?.list()
        items = listing?.items ?? []
        groups = listing?.groups ?? [.personal]
        if let selectedGroupID, !groups.contains(where: { $0.id == selectedGroupID }) {
            selectGroup(nil)
        }
        if let selection, !scopedItems.contains(where: { $0.id == selection }) {
            self.selection = nil
            detail = nil
        }
    }

    func reload() async {
        await run {
            try await refreshListing()
            if let selection {
                detail = try await backend?.item(selection)
            }
        }
    }

    // MARK: - Groups

    private func updateGroups<T>(_ update: (VaultBackend) async throws -> T) async -> T? {
        var result: T?
        await run {
            guard let backend else { return }
            result = try await update(backend)
            try await refreshListing()
        }
        if result != nil, let error { flash(error) }
        return result
    }

    func createGroup(_ name: String) async -> Bool {
        guard let group = await updateGroups({ try await $0.createGroup(name) }) else { return false }
        if groups.contains(where: { $0.id == group.id }) { selectGroup(group.id) }
        return true
    }

    func renameGroup(_ id: VaultGroup.ID, to name: String) async -> Bool {
        await updateGroups { try await $0.renameGroup(id, to: name) } != nil
    }

    func deleteGroup(_ id: VaultGroup.ID) async -> Bool {
        guard let moved = await updateGroups({ try await $0.deleteGroup(id) }) else { return false }
        if error == nil {
            let destination = groupTitle(VaultGroup.personal.id)
            if moved == 1 {
                flash(String(localized: "Group deleted. One item moved to \(destination)."))
            } else if moved > 1 {
                flash(String(localized: "Group deleted. \(moved) items moved to \(destination)."))
            } else {
                flash(String(localized: "Group deleted."))
            }
        }
        return true
    }

    func moveItem(_ name: String, to group: VaultGroup.ID) async -> Bool {
        guard await updateGroups({ try await $0.moveItem(name, to: group) }) != nil else { return false }
        if error == nil { flash(String(localized: "Moved to \(groupTitle(group))")) }
        return true
    }

    func select(_ name: String?) async {
        selection = name
        guard let name else {
            detail = nil
            return
        }
        await run { detail = try await backend?.item(name) }
    }

    func reveal(_ field: String) async -> String? {
        guard let name = detail?.name else { return nil }
        var value: String?
        await run { value = try await backend?.reveal(name, field: field) }
        return value
    }

    func otp() async -> OTPCode? {
        guard let name = detail?.name else { return nil }
        var code: OTPCode?
        await run { code = try await backend?.otp(name) }
        return code
    }

    func otpLink() async -> OTPLink? {
        guard let name = detail?.name else { return nil }
        var link: OTPLink?
        await run { link = try await backend?.otpLink(name) }
        return link
    }

    func copySecret(_ field: String, label: String) async {
        guard let value = await reveal(field) else { return }
        Clipboard.copySecret(value)
        flash(String(localized: "Copied \(label) · clears in \(Int(Clipboard.clearAfter))s"))
    }

    func copyOTP() async {
        guard let code = await otp() else { return }
        Clipboard.copySecret(code.code)
        flash(String(localized: "Copied 2FA code"))
    }

    func copyPlain(_ value: String, label: String) {
        Clipboard.copy(value)
        flash(String(localized: "Copied \(label)"))
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == message { toast = nil }
        }
    }

    func save(_ request: SaveRequest) async -> Bool {
        var ok = false
        await run {
            try await backend?.save(request)
            ok = true
            await reload()
            if request.originalName == nil { showCreated(request.name) }
            if scopedItems.contains(where: { $0.name == request.name }) {
                await select(request.name)
            } else {
                await select(nil)
            }
        }
        return ok
    }

    func delete(_ name: String) async {
        await run {
            try await backend?.delete(name)
            selection = nil
            detail = nil
            await reload()
        }
    }

    /// Make or import an SSH key, then show it. Returns false on failure;
    /// `needsPassphrase` is set when an imported file needs one.
    func addSSHKey(name: String, make: (VaultBackend) async throws -> SSHKeyInfo) async -> (ok: Bool, needsPassphrase: Bool) {
        var ok = false
        var needsPassphrase = false
        await run {
            guard let backend else { return }
            do {
                _ = try await make(backend)
            } catch let e as BackendError where e.needsPassphrase {
                needsPassphrase = true
                throw e
            }
            ok = true
            await reload()
            showCreated(name)
            await select(name)
        }
        return (ok, needsPassphrase)
    }

    /// After creating an item, make sure the list shows it. If the view
    /// you're on wouldn't (another category, a folder it isn't in, or a
    /// search it doesn't match), go to the item's category and clear the
    /// search, and say where it went. Edits never move you: an item keeps
    /// its kind.
    func showCreated(_ name: String) {
        guard let item = items.first(where: { $0.name == name }) else { return }
        var movedTo: String?
        if let selectedGroupID, selectedGroupID != item.groupID {
            self.selectedGroupID = item.groupID
            movedTo = groupTitle(item.groupID)
        }
        if !matches(item, filter) {
            filter = .kind(item.kind)
            movedTo = scopeTitle
        }
        if !search.isEmpty && !filtered.contains(where: { $0.name == name }) {
            search = ""
        }
        if let movedTo { flash(String(localized: "Saved to \(movedTo)")) }
    }

    /// Import the chosen entries of an export file, then show the vault
    /// with them. `nil` on failure (`error` says why) or a cancelled
    /// Touch ID prompt.
    func importItems(path: String, entries: [ImportPreview.Entry]) async -> ImportResult? {
        var result: ImportResult?
        await run {
            result = try await backend?.importItems(
                path: path, indices: entries.map(\.index), names: entries.map(\.name))
            await reload()
            // A category, folder, or search could hide what came in: show
            // everything instead.
            if let result, !result.added.isEmpty, selectedGroupID != nil || filter != .all || !search.isEmpty {
                selectGroup(nil)
            }
        }
        return result
    }

    func generate(length: Int, symbols: Bool) async -> String? {
        var pw: String?
        await run { pw = try await backend?.generate(length: length, symbols: symbols) }
        return pw
    }
}

/// Sample data for snapshots and SwiftUI previews. Nothing here is real.
final class MockBackend: VaultBackend {
    var locked: Bool
    private var groups: [VaultGroup] = [.personal]
    private var nextGroupID: VaultGroup.ID = 1
    var items: [ItemSummary] = {
        let now = Int(Date().timeIntervalSince1970)
        return [
            .init(name: "github", kind: .login, username: "octocat", url: "https://github.com", hasOtp: true, updated: now - 7_200),
            .init(name: "openai/api-key", kind: .secret, username: nil, url: nil, hasOtp: false, updated: now - 86_400),
            .init(name: "stripe/secret-key", kind: .secret, username: nil, url: nil, hasOtp: false, updated: now - 3 * 86_400),
            .init(name: "stripe/dashboard", kind: .login, username: "billing@acme.dev", url: "https://dashboard.stripe.com", hasOtp: true, updated: now - 5 * 86_400),
            .init(name: "work/aws-console", kind: .login, username: "s.aran@acme.dev", url: "https://console.aws.amazon.com", hasOtp: true, updated: now - 9 * 86_400),
            .init(name: "work/vercel", kind: .login, username: "samus", url: "https://vercel.com", hasOtp: false, updated: now - 12 * 86_400),
            .init(name: "work/database-url", kind: .secret, username: nil, url: nil, hasOtp: false, updated: now - 20 * 86_400),
            .init(name: "cloudflare/api-token", kind: .secret, username: nil, url: nil, hasOtp: false, updated: now - 26 * 86_400),
            .init(name: "linear", kind: .login, username: "samus@acme.dev", url: "https://linear.app", hasOtp: false, updated: now - 40 * 86_400),
            .init(name: "notes/home-wifi", kind: .note, username: nil, url: nil, hasOtp: false, updated: now - 60 * 86_400),
            .init(name: "cards/visa", kind: .card, username: nil, url: nil, hasOtp: false, updated: now - 4 * 86_400,
                  subtitle: "Visa •••• 4242 · 08/27"),
            .init(name: "cards/amex-business", kind: .card, username: nil, url: nil, hasOtp: false, updated: now - 30 * 86_400,
                  subtitle: "American Express •••• 0005 · 11/28"),
            .init(name: "ssh/github", kind: .ssh, username: nil, url: nil, hasOtp: false, updated: now - 2 * 86_400,
                  subtitle: "Ed25519 · SHA256:2OdYwq/ygWHl…"),
            .init(name: "banks/chase-checking", kind: .bank, username: nil, url: nil, hasOtp: false, updated: now - 14 * 86_400,
                  subtitle: "Chase · Checking •••• 6789"),
            .init(name: "notes/recovery-codes", kind: .note, username: nil, url: nil, hasOtp: false, updated: now - 90 * 86_400),
        ]
    }()

    /// Snapshots of the lock screen stay locked (Touch ID "cancelled").
    var stayLocked: Bool
    var touchIDAvailable = true
    var touchIDEnabled = true
    private(set) var touchIDRequests = 0

    init(locked: Bool) {
        self.locked = locked
        stayLocked = locked
    }

    func status() async throws -> VaultStatus {
        .init(version: "0.7.0", vaultPath: "~/.stash/vault.db", vaultExists: true, locked: locked,
              touchIdAvailable: touchIDAvailable, touchIdEnabled: touchIDEnabled, needsUpgrade: false)
    }
    func createVault(password: String) async throws {}
    func unlock(password: String) async throws { locked = false }
    func unlockWithTouchID() async throws {
        touchIDRequests += 1
        if stayLocked { throw BackendError(code: -32004, message: "cancelled") }
        locked = false
    }
    func lock() async throws { locked = true }
    func list() async throws -> VaultListing {
        guard !locked else { throw BackendError(code: -32001, message: "stash is locked") }
        return VaultListing(items: items, groups: groups)
    }
    func createGroup(_ name: String) async throws -> VaultGroup {
        let group = VaultGroup(id: nextGroupID, name: name)
        nextGroupID += 1
        groups.append(group)
        return group
    }
    func renameGroup(_ id: VaultGroup.ID, to name: String) async throws {
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            throw BackendError(code: -32011, message: "Group not found")
        }
        groups[index].name = name
    }
    func deleteGroup(_ id: VaultGroup.ID) async throws -> Int {
        guard id != VaultGroup.personal.id else {
            throw BackendError(code: -32012, message: "The default group cannot be deleted.")
        }
        groups.removeAll { $0.id == id }
        let moved = items.indices.filter { items[$0].groupID == id }
        for index in moved { items[index].groupId = nil }
        return moved.count
    }
    func moveItem(_ name: String, to group: VaultGroup.ID) async throws {
        guard let index = items.firstIndex(where: { $0.name == name }) else {
            throw BackendError(code: -32002, message: "Item not found")
        }
        items[index].groupId = group
    }
    func item(_ name: String) async throws -> ItemDetail {
        let summary = items.first { $0.name == name }!
        var fields: [FieldInfo] = []
        switch summary.kind {
        case .login:
            fields = [
                .init(label: "username", kind: .text, value: summary.username),
                .init(label: "password", kind: .concealed, value: nil),
                .init(label: "website", kind: .url, value: summary.url),
            ]
            if summary.hasOtp { fields.append(.init(label: "one-time password", kind: .otp, value: nil)) }
        case .secret:
            fields = [.init(label: "value", kind: .concealed, value: nil)]
        case .note:
            fields = []
        case .card:
            fields = [
                .init(label: "cardholder", kind: .text, value: "Samus Aran"),
                .init(label: "number", kind: .concealed, value: nil),
                .init(label: "expiry", kind: .text, value: "08/27"),
                .init(label: "cvv", kind: .concealed, value: nil),
                .init(label: "billing zip", kind: .text, value: "12345"),
            ]
        case .ssh:
            fields = [
                .init(label: "private key", kind: .concealed, value: nil),
                .init(label: "public key", kind: .text,
                      value: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO60iQ4pgY5/xWYrWhdrOrpEvKYcKJnSet59LRMQ1vFq samus@mac"),
                .init(label: "fingerprint", kind: .text, value: "SHA256:2OdYwq/ygWHlId1JmNr04FYAgHKLr7ntZGcoJfk2lDY"),
            ]
        case .bank:
            fields = [
                .init(label: "bank", kind: .text, value: "Chase"),
                .init(label: "account holder", kind: .text, value: "Samus Aran"),
                .init(label: "account type", kind: .text, value: "checking"),
                .init(label: "routing number", kind: .text, value: "021000021"),
                .init(label: "account number", kind: .concealed, value: nil),
            ]
        }
        let card = summary.kind == .card
            ? CardFace(brand: summary.subtitle?.components(separatedBy: " •").first ?? "Card",
                       last4: String(summary.subtitle?.split(separator: " ").dropLast(2).last ?? "4242"))
            : nil
        return .init(name: name, kind: summary.kind, subtitle: summary.subtitle, card: card, fields: fields,
                     hasNotes: summary.kind == .login || summary.kind == .note, binary: false,
                     created: summary.updated, updated: summary.updated)
    }
    func reveal(_ name: String, field: String) async throws -> String {
        field == "cvv" ? (name.contains("amex") ? "4321" : "123") : "correct-horse-battery"
    }
    func otp(_ name: String) async throws -> OTPCode { .init(code: "482913", remaining: 18, period: 30) }
    func otpLink(_ name: String) async throws -> OTPLink {
        .init(uri: "otpauth://totp/\(name):octocat?secret=JBSWY3DPEHPK3PXP&issuer=\(name)", issuer: name, account: "octocat")
    }
    func save(_ request: SaveRequest) async throws {
        // Enough for the app's flows to work on sample data.
        let value = { (label: String) in request.fields.first { $0.label == label }?.value ?? nil }
        let old = items.first { $0.name == request.originalName }
        let summary = ItemSummary(name: request.name, kind: request.kind, username: value("username"),
                                  url: value("website"), hasOtp: false, updated: Int(Date().timeIntervalSince1970),
                                  groupId: request.groupID ?? old?.groupID)
        items.removeAll { $0.name == (request.originalName ?? request.name) }
        items.append(summary)
    }
    func delete(_ name: String) async throws {}
    func generate(length: Int, symbols: Bool) async throws -> String { "q7#Vd!xP2m@Kz9&Lw4$Rt8" }
    func enableTouchID(password: String) async throws {}
    func sshGenerate(name: String, comment: String?, groupID: VaultGroup.ID?) async throws -> SSHKeyInfo {
        if !items.contains(where: { $0.name == name }) {
            items.append(.init(name: name, kind: .ssh, username: nil, url: nil, hasOtp: false,
                               updated: Int(Date().timeIntervalSince1970), groupId: groupID))
        }
        return .init(publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO60iQ4pgY5/xWYrWhdrOrpEvKYcKJnSet59LRMQ1vFq \(comment ?? name)",
              fingerprint: "SHA256:2OdYwq/ygWHlId1JmNr04FYAgHKLr7ntZGcoJfk2lDY")
    }
    func importPreview(path: String) async throws -> ImportPreview {
        .init(format: "Chrome, Brave, Edge, or Arc", entries: [
            .init(index: 0, title: "GitHub", name: "github", kind: .login, username: "octocat",
                  website: "https://github.com/login", subtitle: nil, warnings: []),
            .init(index: 1, title: "Netflix", name: "netflix.com", kind: .login, username: "samus@acme.dev",
                  website: "https://www.netflix.com", subtitle: nil, warnings: []),
            .init(index: 2, title: "Chase Sapphire", name: "cards/chase-sapphire", kind: .card, username: nil,
                  website: nil, subtitle: "Visa •••• 4242 · 08/27", warnings: []),
            .init(index: 3, title: "Router", name: "router", kind: .login, username: "admin",
                  website: "http://192.168.1.1", subtitle: nil,
                  warnings: ["its 2FA secret was left out (not a valid 2FA (TOTP) secret)"]),
            .init(index: 4, title: "Wi-Fi", name: "notes/wi-fi", kind: .note, username: nil,
                  website: nil, subtitle: nil, warnings: []),
        ], skipped: [.init(title: "Old card", why: "that card number doesn't pass its checksum (a typo?)")])
    }
    func importItems(path: String, indices: [Int], names: [String]) async throws -> ImportResult {
        let preview = try await importPreview(path: path)
        let chosen = preview.entries.filter { indices.contains($0.index) }
        for e in chosen where !items.contains(where: { $0.name == e.name }) {
            items.append(.init(name: e.name, kind: e.kind, username: e.username, url: e.website,
                               hasOtp: false, updated: Int(Date().timeIntervalSince1970), subtitle: e.subtitle))
        }
        return .init(added: chosen.map(\.kind), same: 0, renamed: [], failed: [])
    }
    func sshImport(name: String, key: String, passphrase: String?, groupID: VaultGroup.ID?) async throws -> SSHKeyInfo {
        try await sshGenerate(name: name, comment: nil, groupID: groupID)
    }
}
