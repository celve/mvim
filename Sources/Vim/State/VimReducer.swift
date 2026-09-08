/// The sole writer of `VimState`.
///
/// The executor hands the reducer each `commit` step it *passes*, with the
/// plan's capture slots gathered alongside; a failed step drops every commit
/// behind it except residency (`VimEffect.survivesAbort`), so state tracks
/// what happened to the field plus the mode the user asked for. A
/// capture-backed register write whose slot was never filled is skipped —
/// no content is better than invented content.
public enum VimReducer {
    public static func reduce(
        _ state: VimState,
        _ effect: VimEffect,
        captures: [CaptureSlot: String] = [:]
    ) -> VimState {
        var next = state
        switch effect {
        case .setMode(let mode):
            next.field.mode = mode
            if case .normal = mode {} else {
                next.field.cursor = nil   // the block never survives leaving Normal
            }
            // Opening a session, never merely leaving Normal: `insertStart` is
            // `gi`'s memory and outlives Visual. The paired `setInsertStart`
            // refills it, so an abort that never reaches it leaves it unknown.
            if mode.isInserting { next.field.insertStart = nil }
        case .setInsertStart(let offset):
            next.field.insertStart = offset
        case .searched(let memory):
            next.session.lastSearch = memory
        case .found(let memory):
            next.session.lastFind = memory
        case .setLastInsert(let typed):
            next.session.lastInsert = typed
        case .setLastChange(let change):
            next.session.lastChange = change
        case .setLastVisual(let memory):
            next.field.lastVisual = memory
        case .setMark(let name, let point):
            next.field.marks[name] = point
        case .setCursor(let range):
            next.field.cursor = range
        case .deleted(let register, let payload, let wise):
            guard let slot = resolve(payload, wise: wise, captures: captures) else { break }
            switch slot {
            case .content(let content):
                write(content, to: register, yank: false, in: &next.session.registers)
            case .pasteboard(let wise):
                writeMarker(wise: wise, to: register, in: &next.session.registers)
            }
        case .yanked(let register, let payload, let wise):
            guard let slot = resolve(payload, wise: wise, captures: captures) else { break }
            switch slot {
            case .content(let content):
                write(content, to: register, yank: true, in: &next.session.registers)
            case .pasteboard(let wise):
                writeMarker(wise: wise, to: register, in: &next.session.registers)
            }
        }
        return next
    }

    private static func resolve(
        _ payload: TextPayload,
        wise: Wise,
        captures: [CaptureSlot: String]
    ) -> RegisterSlot? {
        switch payload {
        case .literal(let text):
            return .content(RegisterContent(text: text, wise: wise))
        case .captured(let slot):
            guard let text = captures[slot] else { return nil }
            return .content(RegisterContent(text: text, wise: wise))
        case .pasteboard:
            return .pasteboard(wise: wise)
        }
    }

    /// The register routing lore, in its one home:
    ///
    /// - Every yank and delete mirrors into the unnamed register.
    /// - Default-routed yanks land in `0`; linewise deletes shift the 1–9
    ///   ring; sub-line deletes go to `-`.
    /// - Uppercase names append to their lowercase slot (keeping its wise).
    /// - `_` swallows everything; `+`/`*` mirror to unnamed only — the
    ///   pasteboard itself is the runtime's to write.
    /// A pasteboard marker ignores its register name entirely: the marker
    /// goes to unnamed and NOWHERE else. Ring/`0`/`-`/named routing is
    /// skipped — every marker aliases the one pasteboard, and a ring of
    /// aliases would silently rewrite the meaning of nine slots on every
    /// cut. Uppercase append is skipped too: appending needs text a marker
    /// doesn't have without an impure read, which is exactly the wait this
    /// design deletes. Slots keep their last real content — stale but
    /// honest.
    private static func writeMarker(
        wise: Wise,
        to register: Register?,
        in registers: inout VimState.Registers
    ) {
        guard register?.name != "_" else { return }
        registers.unnamed = .pasteboard(wise: wise)
    }

    private static func write(
        _ content: RegisterContent,
        to register: Register?,
        yank: Bool,
        in registers: inout VimState.Registers
    ) {
        guard register?.name != "_" else { return }
        registers.unnamed = .content(content)

        guard let name = register?.name else {
            if yank {
                registers.numbered[0] = content
            } else if content.wise == .line {
                shiftRing(&registers, insert: content)
            } else {
                registers.smallDelete = content
            }
            return
        }

        switch name {
        case "a"..."z":
            registers.named[name] = content
        case "A"..."Z":
            guard let lowered = name.lowercased().first else { return }
            let existing = registers.named[lowered]
            let combined = RegisterContent(
                text: (existing?.text ?? "") + content.text,
                wise: existing?.wise ?? content.wise
            )
            registers.named[lowered] = combined
            registers.unnamed = .content(combined)
        case "0"..."9":
            guard let digit = name.wholeNumberValue, registers.numbered.indices.contains(digit) else {
                return
            }
            registers.numbered[digit] = content
        default:
            break
        }
    }

    private static func shiftRing(_ registers: inout VimState.Registers, insert content: RegisterContent) {
        var index = 9
        while index > 1 {
            registers.numbered[index] = registers.numbered[index - 1]
            index -= 1
        }
        registers.numbered[1] = content
    }
}
