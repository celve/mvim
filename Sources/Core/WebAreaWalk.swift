/// The parent walk from a web field to the web area that names its site, with the AX read
/// and the clock injected so where it stops — which decides the field's identity — is under `make test`.
public enum WebAreaWalk {
    /// Deep enough for editors nested in app layouts; a field past the cap keys at the app rung.
    public static let maxHops = 64

    /// Seconds; a healthy app answers a hop in well under a millisecond, so only a stalled one spends this.
    public static let budget = 0.5

    /// A URL cut down to the only parts allowed out of the AX layer.
    public struct Address: Equatable, Sendable {
        public var scheme: String?
        public var host: String?

        public init(scheme: String?, host: String?) {
            self.scheme = scheme
            self.host = host
        }
    }

    /// One hop's batched read of one element.
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
        /// Nil when the web area exposed no URL.
        case webArea(Address?)
        case window
        case application
        case orphan(axError: Int32?)
        case hopCap
        case budget
    }

    public struct Result: Equatable, Sendable {
        public let stop: Stop
        /// The element the walk stopped at; 0 is the field itself.
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
    /// Why the walk ended where it did; a URL's scheme is the most of the page it carries.
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
