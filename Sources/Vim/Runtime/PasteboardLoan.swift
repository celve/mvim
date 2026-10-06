import AppKit

/// A register paste's pasteboard loan; AppKit runs lazy providers only on the busy main thread, so none can time it.
@MainActor
final class PasteboardLoan {
    static let shared = PasteboardLoan(.general)

    /// How long a paste no settle saw land stays up: its target may not have reached the ⌘V yet.
    static let unconfirmedHold: TimeInterval = 1

    /// nspasteboard.org's marker for content "replaced or restored shortly", which clipboard histories skip.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard

    /// Every item's types in its own order, with their data; nil while nothing is borrowed.
    private var saved: [[(NSPasteboard.PasteboardType, Data)]]?
    private var stamp = 0
    private var generation = 0

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// A text still up from an earlier put is uvim's own, so the user's contents saved then are kept.
    func put(_ text: String) {
        if saved == nil || pasteboard.changeCount != stamp {
            saved = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transient)
        stamp = pasteboard.changeCount
        generation += 1
        restore(after: Self.unconfirmedHold)
    }

    func landed() {
        restore(after: 0)
    }

    /// Gives the user's contents back, unless something wrote since the put: a cut or a copy is newer and wins.
    func restore() {
        guard let saved else { return }
        self.saved = nil
        guard pasteboard.changeCount == stamp else { return }
        pasteboard.clearContents()
        let items = saved.filter { !$0.isEmpty }.map { flavours in
            let item = NSPasteboardItem()
            for (type, data) in flavours { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func restore(after delay: TimeInterval) {
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == generation else { return }
                self.restore()
            }
        }
    }
}
