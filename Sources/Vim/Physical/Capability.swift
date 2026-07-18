/// The probeable atoms of what a focused field can do, each mapping to one
/// concrete AX mechanism. Ambient powers (key synthesis, clipboard
/// transactions, ⌘Z) are permission-level constants, not capabilities.
public enum Capability: String, CaseIterable, Equatable, Hashable, Sendable {
    /// `AXValue` / `AXStringForRange`: the field's text can be read.
    case readText

    /// `AXNumberOfCharacters`: cheap length reads for settle checks.
    case readLength

    /// `AXSelectedTextRange` (get): caret and selection can be read.
    case readCaret

    /// `AXSelectedText` (get): selection content without the clipboard.
    case readSelectedText

    /// `AXSelectedTextRange` (set): the golden write — exact select/move.
    case writeSelection

    /// `AXSelectedText` (set): exact insertion/replacement.
    case insertText
}

public enum CapabilityStatus: String, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

/// A frozen per-field answer the physical planner consults. The runtime
/// prober fills it (static probe on focus, lazy write probe, learned
/// per-app priors) and refreshes it when focus moves; the planner never
/// talks to AX. At planning time only `.available` counts — an unknown
/// capability is planned around, never assumed.
public struct CapabilityProfile: Equatable, Sendable {
    public var statuses: [Capability: CapabilityStatus]

    public init(statuses: [Capability: CapabilityStatus] = [:]) {
        self.statuses = statuses
    }

    public init(available: Set<Capability>) {
        statuses = Dictionary(uniqueKeysWithValues: available.map { ($0, .available) })
    }

    public func has(_ capability: Capability) -> Bool {
        statuses[capability] == .available
    }
}
