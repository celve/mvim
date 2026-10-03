/// Refuted runs in a row of each write or key at one rung, this process; the `limit`th switches it off.
public struct Strikes: Equatable, Sendable {
    public static let limit = 3

    /// The opt-in app keys (`nativeMotions`) keep the one-miss rule.
    public static func limit(for capability: Capability) -> Int {
        capability == .wordKeys || capability == .paragraphKeys ? 1 : limit
    }

    private struct Count: Equatable, Sendable {
        var judgedUnder: OffsetsAnswer
        var app: String?
        var runs: Int
    }

    private var counts: [Capability: Count] = [:]

    /// Optional routes that missed here, which no later pass brings back (LIN-1686).
    private var missed: [Route: Count] = [:]

    public init() {}

    public var isEmpty: Bool { counts.isEmpty && missed.isEmpty }

    public func runs(_ capability: Capability) -> Int { counts[capability]?.runs ?? 0 }

    /// A settle that passed on a write or key clears its count.
    public mutating func pass(_ run: [Evidence]) {
        for item in run where item.outcome == .supports(nil) {
            if let capability = item.question.capability { counts[capability] = nil }
        }
    }

    /// One miss ends an optional route: counting reaches the same landing without it.
    public mutating func miss(_ route: Route, judgedUnder offsets: OffsetsAnswer, app: String?) {
        missed[route] = Count(judgedUnder: offsets, app: app, runs: 1)
    }

    /// The routes to plan without under this offsets answer and app version.
    public func missed(judgedUnder offsets: OffsetsAnswer, app: String?) -> Set<Route> {
        Set(missed.filter { $0.value.judgedUnder == offsets && $0.value.app == app }.keys)
    }

    /// The runs in a row so far, this one included; a strike under another offsets answer or app version starts over.
    mutating func strike(_ capability: Capability, judgedUnder offsets: OffsetsAnswer, app: String?) -> Int {
        var count = counts[capability] ?? Count(judgedUnder: offsets, app: app, runs: 0)
        if count.judgedUnder != offsets || count.app != app { count = Count(judgedUnder: offsets, app: app, runs: 0) }
        count.runs += 1
        counts[capability] = count
        return count.runs
    }

    mutating func clear(_ capability: Capability) {
        counts[capability] = nil
    }
}
