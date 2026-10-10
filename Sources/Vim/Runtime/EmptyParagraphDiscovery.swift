import ApplicationServices
import Core

/// `EmptyBlockScan` over a Chromium field's accessibility tree, for `EmptyParagraphs.restore` (LIN-1612).
enum EmptyParagraphDiscovery {
    /// Plain offsets in `markers` of the `<br>`s of line-starting empty blocks; nil on a failed read or past `budget` reads.
    static func found(
        in element: AXUIElement, markers: String, budget: Int
    ) -> (found: [Int]?, exhausted: Bool, reads: Discovery.Reads) {
        let plain = Array(markers.utf16).filter { $0 != 0xFFFC }
        guard plain.contains(10) else { return ([], false, Discovery.Reads(budget: budget - 2)) }
        guard let tree = FieldTree(element, markers: markers) else { return (nil, false, Discovery.Reads(budget: budget - 2)) }
        let recorder = Discovery.Recorder(budget: budget - 2, block: tree.block, offset: tree.offset)
        var scan = EmptyBlockScan(budget: budget - 2, block: recorder.block, offset: recorder.offset)
        return (scan.run(blocks: recorder.roots(tree.blocks), plain: plain), scan.exhausted, recorder.reads)
    }
}

/// `UnreachableScan` over a Chromium field's accessibility tree, for `UnreachableLines.fold` (LIN-1652).
enum UnreachableDiscovery {
    /// Nil on a failed read or past `budget` reads.
    static func found(
        in element: AXUIElement, markers: String, candidates: UnreachableLines.Candidates, budget: Int
    ) -> (found: UnreachableLines.Found?, exhausted: Bool, reads: Discovery.Reads) {
        let reads = Discovery.Reads(budget: budget - 2)
        guard !candidates.isEmpty else { return (UnreachableLines.Found(markers: [], chips: []), false, reads) }
        guard let tree = FieldTree(element, markers: markers) else { return (nil, false, reads) }
        let recorder = Discovery.Recorder(budget: budget - 2, block: tree.block, offset: tree.offset)
        var scan = UnreachableScan(budget: budget - 2, block: recorder.block, offset: recorder.offset)
        return (scan.run(blocks: recorder.roots(tree.blocks), candidates: candidates), scan.exhausted, recorder.reads)
    }
}

/// The reads both discoveries descend a Chromium field's tree by.
struct FieldTree {
    let blocks: [AXUIElement]
    let block: (AXUIElement) -> EmptyBlockScan<AXUIElement>.Block?
    let offset: (AXUIElement, _ end: Bool) -> Int?

    init?(_ element: AXUIElement, markers: String) {
        guard let start = AX.fieldStart(of: element), let blocks = AX.children(of: element) else { return nil }
        // Marker lengths count each U+FFFC before them, plain offsets do not.
        var objects = [0]
        objects.reserveCapacity(markers.utf16.count + 1)
        for unit in markers.utf16 { objects.append(objects[objects.count - 1] + (unit == 0xFFFC ? 1 : 0)) }
        self.blocks = blocks
        block = { node in
            let reads = AX.attributes(
                [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, "AXDOMClassList", "AXBlockQuoteLevel"], of: node
            )
            guard (0..<3).allSatisfy({ Self.absentOrRead(reads, $0) }) else { return nil }
            // The last two only add Linear's stops and controls, so one that fails reads as none.
            return EmptyBlockScan.Block(
                role: reads.string(0), subrole: reads.string(1), children: reads.elements(2) ?? [],
                classes: reads.strings(3) ?? [], quoteLevel: reads.int(4) ?? 0
            )
        }
        offset = { node, end in
            guard let length = AX.markerLength(from: start, to: node, end: end, in: element),
                  objects.indices.contains(length) else { return nil }
            return length - objects[length]
        }
    }

    /// A slot that read, or whose attribute the element lacks; any other failure is a failed read.
    private static func absentOrRead(_ reads: AX.AttributeBatch, _ index: Int) -> Bool {
        guard let error = reads.error(index) else { return true }
        return error == .noValue || error == .attributeUnsupported
    }
}
