import AppKit
import Core
import SwiftUI
import Vim

/// mvim's composition root: a menu-bar agent (LSUIElement) whose only UI is
/// the status menu. The tap feeds the `Controller`; everything else is
/// permission plumbing.
@main
struct MvimApp: App {
    @StateObject private var model = AppModel()
    private let updater = Updater.start()

    var body: some Scene {
        MenuBarExtra {
            Toggle("Vim Mode", isOn: $model.vimEnabled)
            Picker("Normal Mode Key", selection: $model.normalModeKey) {
                Text("⌃[").tag(NormalModeKey.controlBracket)
                Text("Esc").tag(NormalModeKey.escape)
            }
            if let front = model.frontApp {
                Picker("Vim in \(front.name)", selection: Binding(
                    get: { model.frontAppPolicy },
                    set: { model.setFrontAppPolicy($0) }
                )) {
                    Text("Auto").tag(VimPolicy.auto)
                    Text("Off").tag(VimPolicy.off)
                    Text("Force").tag(VimPolicy.forced)
                }
                CapabilitiesItem(
                    title: "Capabilities in \(model.surfaceLabel)", menu: model.capabilities,
                    choose: model.setCapabilityOverride, forget: model.forget, clear: model.clearOverrides
                )
            }
            Divider()
            Text(model.tapInstalled ? "Input tap: running" : "Input tap: not installed")
                .onAppear { model.refresh() }
            Button(model.accessibilityTrusted ? "Accessibility: granted" : "Accessibility: not granted") {
                model.openPrivacyPane("Privacy_Accessibility")
            }
            Button(model.inputMonitoringGranted
                ? "Input Monitoring: granted"
                : "Input Monitoring: not granted — grant, then relaunch") {
                model.openPrivacyPane("Privacy_ListenEvent")
            }
            Divider()
            // Checked answers "will mvim start at login?" — a revoked item is not.
            Toggle("Start at Login", isOn: Binding(
                get: { model.loginItem == .on },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginItem == .blocked {
                Button("Approve mvim in Login Items Settings") { model.openLoginItemsSettings() }
            }
            Button(model.beliefsReadable ? "Open Beliefs File" : "Open Beliefs File — unreadable, last good version in use") {
                model.openBeliefsFile()
            }
            if let updater {
                Divider()
                UpdateItems(updater: updater)
            }
            Divider()
            Button("Quit mvim") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: model.icon.symbolName)
        }
    }
}

/// Its own view so the menu observes `Updater`, which `AppModel` does not own.
private struct UpdateItems: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button(updater.pendingVersion.map { "Update to mvim \($0)…" } ?? "Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Toggle("Check for Updates Automatically", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        ))
    }
}

/// The Capabilities item: a badge counts what mvim learned for this field, and the submenu opens on it.
struct CapabilitiesItem: View {
    /// Subtitles and badges were checked on macOS 26 only; older systems get everything in the title.
    static var richItemsAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    let title: String
    let menu: AppModel.CapabilityMenu
    let choose: @MainActor (CapabilityConfig.Override?, String?, Capability) -> Void
    let forget: @MainActor ([Belief]) -> Void
    let clear: @MainActor (String) -> Void
    var richItems = CapabilitiesItem.richItemsAvailable

    var body: some View {
        Menu(richItems ? title : joined(title, menu.badge)) {
            // Text, not Section: SwiftUI draws a separator above every section, even atop a submenu.
            if let header = menu.learnedHeader {
                Text(header)
                ForEach(menu.learned) { submenu(for: $0) }
                if let forgetAll = menu.forgetAll {
                    Button(forgetAll) { forget(menu.learned.flatMap { $0.lesson?.beliefs ?? [] }) }
                }
                Divider()
            }
            if menu.unbound {
                Text("Not in a field")
            }
            ForEach(menu.rows) { submenu(for: $0) }
            if !menu.clearActions.isEmpty {
                Divider()
                ForEach(menu.clearActions) { action in
                    Button(action.label) { clear(action.rung) }
                }
            }
        }
        .badge(richItems ? menu.badge.map { Text($0) } : nil)
    }

    // Every choice is a sentence naming the rung it writes, so exactly one is ever checked.
    private func submenu(for row: AppModel.CapabilityRow) -> some View {
        Menu {
            if let lesson = row.lesson {
                Text(lesson.header)
                Button {
                    forget(lesson.beliefs)
                } label: {
                    Text(lesson.action)
                    if richItems {
                        Text(lesson.actionDetail)
                    }
                }
                Divider()
            }
            Toggle("Auto — mvim decides", isOn: Binding(
                get: { row.choice == .auto }, set: { if $0 { choose(nil, nil, row.capability) } }
            ))
            Divider()
            ForEach(row.onOptions) { toggle($0, for: row.capability) }
            Divider()
            ForEach(row.offOptions) { toggle($0, for: row.capability) }
        } label: {
            if richItems, let subtitle = row.subtitle {
                Text(row.title)
                Text(subtitle)
            } else {
                Text(joined(row.title, row.subtitle))
            }
        }
    }

    private func toggle(_ option: AppModel.ScopeOption, for capability: Capability) -> some View {
        Toggle(option.label, isOn: Binding(
            get: { option.checked }, set: { if $0 { choose(option.override, option.rung, capability) } }
        ))
    }

    private func joined(_ title: String, _ detail: String?) -> String {
        detail.map { "\(title) — \($0)" } ?? title
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct FrontApp: Equatable {
        let name: String
        let bundleID: String
    }

    /// The menu-bar icon: the only mode display where mvim draws no block cursor.
    enum Icon {
        case off, permissionMissing, idle, insert, normal, visual, replace

        init(vimEnabled: Bool, permitted: Bool, secureInput: Bool, mode: VimState.Mode?) {
            if !vimEnabled {
                self = .off
            } else if !permitted {
                self = .permissionMissing
            } else {
                switch secureInput ? nil : mode {
                case nil: self = .idle
                case .insert?: self = .insert
                case .normal?: self = .normal
                case .visual?: self = .visual
                case .replace?: self = .replace
                }
            }
        }

        /// Outlined where keys type, filled where they are commands.
        var symbolName: String {
            switch self {
            case .off: return "square.slash"
            case .permissionMissing: return "exclamationmark.square"
            case .idle: return "square.dashed"
            case .insert: return "i.square"
            case .normal: return "n.square.fill"
            case .visual: return "v.square.fill"
            case .replace: return "r.square"
            }
        }
    }

    /// One On/Off action inside an atom's submenu: a full sentence and the
    /// rung it writes. Checked when it is the entry currently in force.
    struct ScopeOption: Identifiable, Equatable {
        let label: String
        let rung: String
        let override: CapabilityConfig.Override
        let checked: Bool
        var id: String { rung + "|" + override.rawValue }
    }

    /// One capabilities-menu row: the atom, why it stands as it does here, and every scope it may be written at.
    struct CapabilityRow: Identifiable, Equatable {
        let capability: Capability
        let title: String
        /// Nil where the atom works as detected, or no field is bound and the user chose nothing.
        let subtitle: String?
        let lesson: Lesson?
        let choice: OverrideChoice
        /// Kept apart so the menu can rule between them — a flat list of eight
        /// near-identical sentences is unreadable.
        let onOptions: [ScopeOption]
        let offOptions: [ScopeOption]
        var id: String { capability.rawValue }
    }

    /// What mvim learned behind a row: in force here, or on trial because it was judged under other offsets.
    struct Lesson: Equatable {
        let inForce: Bool
        let header: String
        let action: String
        let actionDetail: String
        /// What the action forgets.
        let beliefs: [Belief]
    }

    /// The Capabilities submenu: the rows mvim learned something about for this kind of field, then the rest.
    struct CapabilityMenu: Equatable {
        var learnedHeader: String?
        var learned: [CapabilityRow] = []
        var rows: [CapabilityRow] = []
        /// No field of the front app is bound, so nothing is detected.
        var unbound = false
        var clearActions: [ClearAction] = []

        /// Lessons on trial here are not counted: nothing is off because of them.
        var badge: String? {
            let count = learned.filter { $0.lesson?.inForce == true }.count
            return count == 0 ? nil : "\(count) learned"
        }

        /// One lesson keeps only its own action.
        var forgetAll: String? {
            guard learned.count > 1 else { return nil }
            let which = learned.count == 2 ? "Both" : "All"
            return learned.allSatisfy { $0.lesson?.inForce == false } ? "Forget \(which)" : "Try \(which) Again"
        }
    }

    /// A "Clear overrides…" item: wipes every atom at a rung and below.
    struct ClearAction: Identifiable, Equatable {
        let label: String
        let rung: String
        var id: String { rung }
    }

    /// Whether an atom currently defers (`auto`) or is pinned by the user.
    enum OverrideChoice: String, CaseIterable {
        case auto, on, off
    }

    @Published private(set) var mode: VimState.Mode?
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var tapInstalled = false
    /// The tracker unbinds under Secure Input only when it next resolves; the icon need not wait.
    @Published private(set) var secureInput = false
    @Published private(set) var frontApp: FrontApp?
    @Published private(set) var frontAppPolicy: VimPolicy = .auto
    @Published private(set) var capabilities = CapabilityMenu()
    @Published private(set) var beliefsReadable = true
    @Published private(set) var loginItem: LoginItem.State = .off
    @Published var vimEnabled = true {
        didSet { controller.enabled = vimEnabled }
    }
    @Published var normalModeKey = Prefs.normalModeKey {
        didSet {
            Prefs.normalModeKey = normalModeKey
            controller.escapeEngages = normalModeKey == .escape
        }
    }

    var icon: Icon {
        Icon(
            vimEnabled: vimEnabled, permitted: accessibilityTrusted && tapInstalled,
            secureInput: secureInput, mode: mode
        )
    }

    private let controller: Controller
    private var token: InputHub.Token?
    private var workspaceToken: NSObjectProtocol?

    init() {
        // Before any AX or binding work: seed the disable list, and bound
        // every AX call this process makes (the system default is ~6s —
        // long enough for one busy app to freeze the tap).
        Prefs.registerDefaults()
        AX.setGlobalMessagingTimeout(0.15)

        let controller = Controller()
        self.controller = controller
        controller.escapeEngages = normalModeKey == .escape
        controller.onModeChange = { [weak self] mode in self?.mode = mode }
        // Its own channel, deliberately: mode changes do NOT ride every rebind
        // — publishMode early-returns when the indicator is unchanged, so
        // moving between two Normal-mode fields fired nothing and the rows kept
        // describing the surface focus had left.
        controller.onBindingChange = { [weak self] in
            self?.refreshCapabilityRows()
        }
        token = InputHub.shared.register(.editor) { event in
            MainActor.assumeIsolated { controller.handle(event) }
        }
        // The menu's "Vim in <app>" row must be current BEFORE the menu is
        // built — MenuBarExtra builds content eagerly, so .onAppear cannot
        // be trusted to re-fire per open. Track activation continuously.
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated { [weak self] in self?.frontAppChanged(note) }
        }
        // Nothing documented announces an Accessibility change or Secure Input, so the icon polls both.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.recheckSystemState() }
        }.tolerance = 1
        refresh()
    }

    /// Assigns only a change: every `@Published` set, equal or not, re-evaluates the whole menu.
    private func recheckSystemState() {
        let trusted = AX.ensureTrusted(prompt: false)
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let secure = SecureInput.isActive
        if secure != secureInput { secureInput = secure }
    }

    private func frontAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleIdentifier else { return }
        frontApp = FrontApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
        frontAppPolicy = Prefs.policy(for: bundleID)
        refreshCapabilityRows()
    }

    func refresh() {
        recheckSystemState()
        inputMonitoringGranted = CGPreflightListenEventAccess()
        tapInstalled = InputHub.shared.isTapInstalled
        loginItem = LoginItem.state
        // mvim is LSUIElement, so opening the menu keeps the target app
        // frontmost; if frontmost somehow IS mvim, keep the last snapshot.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let bundleID = app.bundleIdentifier {
            frontApp = FrontApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
        }
        frontAppPolicy = frontApp.map { Prefs.policy(for: $0.bundleID) } ?? .auto
        refreshCapabilityRows()
    }

    func setFrontAppPolicy(_ policy: VimPolicy) {
        guard let frontApp else { return }
        Prefs.setPolicy(policy, for: frontApp.bundleID)
        frontAppPolicy = policy
        controller.refreshPolicy()
    }

    /// `rung` of nil is Auto, cleared at every rung.
    func setCapabilityOverride(
        _ override: CapabilityConfig.Override?, at rung: String?, for capability: Capability
    ) {
        controller.setOverride(override, at: rung, on: menuSurface, for: capability)
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    func clearOverrides(at rung: String) {
        controller.clearOverrides(atAndBelow: rung, on: menuSurface)
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    func forget(_ beliefs: [Belief]) {
        controller.forget(beliefs)
        controller.refreshCapabilities()
        refreshCapabilityRows()
    }

    func openBeliefsFile() {
        let readable = controller.appliedOverrides().fromFile
        if readable != beliefsReadable { beliefsReadable = readable }
        NSWorkspace.shared.open(controller.beliefsURL)
    }

    /// The surface the menu configures: the bound field's when it belongs to
    /// the front app, otherwise the app alone.
    ///
    /// The fallback is what keeps rows editable while unbound — config is
    /// config, and an app-scope choice is still meaningful with no field in
    /// hand. It also collapses the scope list to just the app, which is
    /// honest: nothing narrower is known.
    private var menuSurface: Surface {
        guard let frontApp else { return Surface() }
        if let bound = controller.boundSurface, bound.bundleID == frontApp.bundleID {
            return bound
        }
        return Surface(bundleID: frontApp.bundleID)
    }

    /// "Dia › notion.so" — the menu must name what it is about to configure,
    /// or a scoped write reads as an app-wide one.
    var surfaceLabel: String {
        guard let frontApp else { return "—" }
        guard let origin = menuSurface.origin else { return frontApp.name }
        return "\(frontApp.name) › \(origin)"
    }

    /// Rebuilt on app activation, rebinds and menu actions; an overlay's binding must not label the front app's rows.
    private func refreshCapabilityRows() {
        let applied = controller.appliedOverrides()
        if applied.fromFile != beliefsReadable { beliefsReadable = applied.fromFile }
        let menu: CapabilityMenu
        if let frontApp {
            let surface = menuSurface
            let bound = controller.boundSurface?.bundleID == frontApp.bundleID
            menu = Self.capabilityMenu(
                app: frontApp.name, surface: surface,
                report: bound ? controller.capabilityReport : nil, beliefs: bound ? controller.boundBeliefs : nil,
                config: CapabilityConfig.resolveAll(
                    surface, capabilities: Capability.allCases.map(\.rawValue), overrides: applied.overrides
                )
            )
        } else {
            menu = CapabilityMenu()
        }
        if menu != capabilities { capabilities = menu }
    }

    /// Every string the Capabilities submenu shows is made here, from one resolution.
    nonisolated static func capabilityMenu(
        app: String, surface: Surface, report: CapabilityReport?, beliefs: ResolvedBeliefs?,
        config: [String: CapabilityConfig.Resolution]
    ) -> CapabilityMenu {
        let scopes = surface.writableScopes
        let overridden = Set(Capability.allCases.filter { config[$0.rawValue]?.override != nil })
        let lessons = report.flatMap { beliefs?.lessons(report: $0, overridden: overridden) } ?? []
        var menu = CapabilityMenu(unbound: report == nil)
        for capability in Capability.allCases {
            let resolution = config[capability.rawValue] ?? .auto
            let choice: OverrideChoice
            switch resolution.override {
            case .on: choice = .on
            case .off: choice = .off
            case nil: choice = .auto
            }
            let learned = lessons.first { $0.capability == capability }.map { self.learned($0, app: app) }
            // Narrowest first; the check marks the user's stored choice, which the probe may overrule.
            func options(_ override: CapabilityConfig.Override) -> [ScopeOption] {
                scopes.map { scope, rung in
                    ScopeOption(
                        label: sentence(override, scope), rung: rung, override: override,
                        checked: resolution.override == override && resolution.overrideRung == rung
                    )
                }
            }
            let row = CapabilityRow(
                capability: capability,
                title: displayName(capability),
                subtitle: learned?.subtitle ?? standing(
                    capability, report: report, resolution: resolution, surface: surface, scopes: scopes,
                    readModel: beliefs?.readModel, app: app
                ),
                lesson: learned?.lesson,
                choice: choice,
                onOptions: options(.on),
                offOptions: options(.off)
            )
            if learned == nil {
                menu.rows.append(row)
            } else {
                menu.learned.append(row)
            }
        }
        if !menu.learned.isEmpty {
            menu.learnedHeader = "Learned for \(kind(of: surface)) \(surface.origin.map { "on \($0)" } ?? "in \(app)")"
        }

        // Only the scopes that could plausibly hold something worth wiping —
        // clearing "this one field" is what Auto already does per atom.
        menu.clearActions = scopes.compactMap { scope, rung in
            switch scope {
            case .site, .app:
                return ClearAction(label: "Clear overrides \(phrase(scope))", rung: rung)
            case .field, .fieldsOfRole:
                return nil
            }
        }
        return menu
    }

    /// The Learned section's words for what the engine says a row learned.
    private nonisolated static func learned(
        _ lesson: ResolvedBeliefs.Lesson, app: String
    ) -> (lesson: Lesson, subtitle: String) {
        let belief = lesson.beliefs[0]
        switch lesson.state {
        case .inForce:
            let row = Lesson(
                inForce: true, header: learnedWhen(belief, app: app), action: "Try Again",
                actionDetail: "Forget this, and stay on Auto", beliefs: lesson.beliefs
            )
            return (row, "Off" + since(belief) + " · " + until(belief, app: app))
        case .reopened:
            let judged = judgedPhrase(belief.judgedUnder ?? .value)
            let row = Lesson(
                inForce: false, header: learnedWhen(belief, app: app), action: "Forget",
                actionDetail: "Try it again \(judged) too", beliefs: lesson.beliefs
            )
            return (row, "Trying again here · failed" + (day(belief).map { " \($0)" } ?? "") + " " + judged)
        }
    }

    /// Why a row outside the Learned section stands as it does; nil where it works as detected.
    private nonisolated static func standing(
        _ capability: Capability, report: CapabilityReport?, resolution: CapabilityConfig.Resolution,
        surface: Surface, scopes: [(scope: Surface.Scope, rung: String)], readModel: ReadModel?, app: String
    ) -> String? {
        let choice = resolution.override.map {
            ($0 == .on ? "On" : "Off") + scopePhrase(resolution.overrideRung, surface: surface, scopes: scopes)
        }
        guard let report, let entry = report.entries[capability] else { return choice.map { $0 + ", your choice" } }
        let parentOff = capability.parent.flatMap { report.entries[$0]?.status == .available ? nil : $0 }
        if let choice {
            guard resolution.override == .on, entry.status != .available else { return choice + ", your choice" }
            return choice + (parentOff.map { ", but \(shortName($0)) is off" } ?? ", but not offered here")
        }
        if entry.status != .available, let parentOff {
            return "Off while \(shortName(parentOff)) is off"
        }
        switch (entry.status, entry.source) {
        case (.unavailable, .seeded): return "Off by default"
        case (.unavailable, .probed): return "Not offered here"
        default: break
        }
        guard capability == .readCaret, let readModel else { return nil }
        switch (readModel.source, readModel.answer) {
        case (.learned, .textContent), (.learned, .value):
            let how = readModel.answer == .textContent ? "Through text markers" : "Through AXValue"
            return readModel.belief.map { how + since($0) + " · " + until($0, app: app) } ?? how
        case (.start, .textContent):
            return "Through text markers, as Chromium rich text needs"
        default:
            return nil
        }
    }

    /// Where a choice was stored, as the On and Off sentences name it; a hand-written `web:` rung spans browsers.
    private nonisolated static func scopePhrase(
        _ rung: String?, surface: Surface, scopes: [(scope: Surface.Scope, rung: String)]
    ) -> String {
        if let scope = scopes.first(where: { $0.rung == rung }) { return " " + phrase(scope.scope) }
        if let origin = surface.origin, rung == Surface.webRung(origin) { return " on \(origin) in any browser" }
        return ""
    }

    /// A read model expires with Electron's version where there is one; verdicts with the app's.
    private nonisolated static func until(_ belief: Belief, app: String) -> String {
        let electron = belief.question == .offsets && belief.engineVersion != nil
        return electron ? "until \(app) updates Electron" : "until \(app) updates"
    }

    private nonisolated static func shortName(_ capability: Capability) -> String {
        String(displayName(capability).split(separator: " (")[0])
    }

    private nonisolated static func learnedWhen(_ belief: Belief, app: String) -> String {
        let version = belief.appVersion.isEmpty ? "" : " \(belief.appVersion)"
        return "Learned" + (day(belief).map { " \($0)" } ?? "") + " in \(app)" + version
    }

    private nonisolated static func since(_ belief: Belief) -> String {
        day(belief).map { " since \($0)" } ?? ""
    }

    /// "Sep 28", with the year when it is not this one.
    private nonisolated static func day(_ belief: Belief) -> String? {
        guard let stamp = belief.provenance.learnedAt, let date = try? Date(stamp, strategy: .iso8601) else {
            return nil
        }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(thisYear ? style : style.year())
    }

    private nonisolated static func judgedPhrase(_ answer: OffsetsAnswer) -> String {
        switch answer {
        case .textContent: return "in rich text"
        case .value: return "in plain text"
        case .untrusted: return "where the caret went unread"
        }
    }

    /// The learner keys on the field's role, so the section names fields by it.
    private nonisolated static func kind(of surface: Surface) -> String {
        switch surface.role {
        case "AXTextArea": return "text areas"
        case "AXTextField": return "text fields"
        case "AXComboBox": return "combo boxes"
        default: return "fields like this one"
        }
    }

    /// UI strings stay in the app layer — `Surface` names rungs, not rows.
    /// Pure string work, so `nonisolated`: the row builder calls it from inside
    /// a `map` closure, which does not inherit the model's actor.
    private nonisolated static func sentence(
        _ override: CapabilityConfig.Override, _ scope: Surface.Scope
    ) -> String {
        "\(override == .on ? "On" : "Off") \(phrase(scope))"
    }

    private nonisolated static func phrase(_ scope: Surface.Scope) -> String {
        switch scope {
        case .field(let identifier): return "in field \"\(identifier)\""
        case .fieldsOfRole: return "in fields like this one"
        case .site(let origin): return "on \(origin)"
        case .app: return "in this app"
        }
    }

    /// UI strings stay in the app layer — the engine names atoms, not rows.
    private nonisolated static func displayName(_ capability: Capability) -> String {
        switch capability {
        case .readText: return "Read text"
        case .readLength: return "Read length"
        case .readCaret: return "Read caret"
        case .readSelectedText: return "Read selected text"
        case .writeSelection: return "Set selection (AX)"
        case .insertText: return "Replace text (AX)"
        case .drawCursor: return "Draw block cursor"
        // Phrased so the row's *denial* is the legible half: "Off by default"
        // then reads as the block-editor fact.
        case .wholeDocument: return "Text covers whole document"
        case .fieldIsSession: return "New field starts a session"
        case .lineStartKey: return "Line start key (⌃A)"
        case .lineEndKey: return "Line end key (⌃E)"
        case .documentStartKey: return "Document start key (⌘↑)"
        case .documentEndKey: return "Document end key (⌘↓)"
        case .nativeMotions: return "App's word, paragraph & page keys"
        case .wordKeys: return "Word keys (⌥← ⌥→)"
        case .paragraphKeys: return "Paragraph keys (⌥↑ ⌥↓)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        Task.detached {
            let state = LoginItem.setEnabled(enabled)
            await MainActor.run { self.loginItem = state }
        }
    }

    func openLoginItemsSettings() {
        LoginItem.openSettings()
    }

    func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
