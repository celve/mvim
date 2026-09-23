/// Walks a web field's ancestors up to the page that names its site; pure, so `make test` covers it.
public enum WebAreaWalk {
    /// Deep enough for editors nested in app layouts.
    public static let maxHops = 64

    /// Seconds; only a stalled app spends it.
    public static let budget = 0.5

    /// A URL cut to the parts allowed out of the AX layer.
    public struct Address: Equatable, Sendable {
        public var scheme: String?
        public var host: String?

        public init(scheme: String?, host: String?) {
            self.scheme = scheme
            self.host = host
        }
    }

    /// One hop's batched read.
    public struct Reading<Node> {
        public var role: String?
        public var address: Address?
        public var parent: Node?
        /// Why `parent` is nil, as an `AXError` raw value.
        public var parentError: Int32?

        public init(role: String?, address: Address? = nil, parent: Node?, parentError: Int32? = nil) {
            self.role = role
            self.address = address
            self.parent = parent
            self.parentError = parentError
        }
    }

    public enum Stop: Equatable, Sendable {
        /// Nil when the page exposed no URL.
        case webArea(Address?)
        case window
        case application
        case orphan(axError: Int32?)
        case hopCap
        case budget
    }

    public struct Result: Equatable, Sendable {
        public let stop: Stop
        /// The element it stopped at (0 is the field); for `hopCap` and `budget`, the first unread.
        public let hops: Int
        public let milliseconds: Int

        public var origin: String? {
            guard case .webArea(let address?) = stop else { return nil }
            return Surface.normalizedHost(address.host)
        }
    }

    public static func walk<Node>(
        from field: Node,
        maxHops: Int = WebAreaWalk.maxHops,
        budget: Double = WebAreaWalk.budget,
        clock: () -> Double,
        read: (Node) -> Reading<Node>
    ) -> Result {
        let start = clock()
        func stopped(_ stop: Stop, at hops: Int) -> Result {
            Result(stop: stop, hops: hops, milliseconds: Int(((clock() - start) * 1000).rounded()))
        }
        var current = field
        for hop in 0..<maxHops {
            if hop > 0, clock() - start >= budget { return stopped(.budget, at: hop) }
            let reading = read(current)
            switch reading.role {
            case "AXWebArea": return stopped(.webArea(reading.address), at: hop)
            // Nothing above a window is web content.
            case "AXWindow": return stopped(.window, at: hop)
            case "AXApplication": return stopped(.application, at: hop)
            default: break
            }
            guard let parent = reading.parent else {
                return stopped(.orphan(axError: reading.parentError), at: hop)
            }
            current = parent
        }
        return stopped(.hopCap, at: maxHops)
    }
}

// MARK: - Recorder

extension WebAreaWalk.Result {
    /// Why the walk stopped; it carries a URL's scheme at most, never the page.
    public var traceFields: String {
        var fields = "stop=\(reason)@\(hops)"
        switch stop {
        case .orphan(let error):
            fields += " axerror=\(error.map(String.init) ?? "nil")"
        case .webArea(let address?) where origin == nil:
            fields += " scheme=\(address.scheme ?? "nil")"
        default:
            break
        }
        return fields + " ms=\(milliseconds)"
    }

    private var reason: String {
        switch stop {
        case .webArea(nil): return "noURL"
        case .webArea: return origin == nil ? "hostless" : "site"
        case .window: return "window"
        case .application: return "application"
        case .orphan: return "orphan"
        case .hopCap: return "hopCap"
        case .budget: return "budget"
        }
    }
}
