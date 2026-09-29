import ApplicationServices
import LoomCore

/// `EmptyBlockScan` over a Chromium field's accessibility tree, for `EmptyParagraphs.restore` (LIN-1612).
enum EmptyParagraphDiscovery {
    /// Plain offsets in `markers` of the `<br>`s of line-starting empty blocks; nil on a failed read or past `budget` reads.
    static func found(in element: AXUIElement, markers: String, budget: Int) -> (found: [Int], reads: Int)? {
        let raw = Array(markers.utf16)
        let plain = raw.filter { $0 != 0xFFFC }
        guard plain.contains(10) else { return ([], 0) }
        guard let start = AX.fieldStart(of: element), let blocks = AX.children(of: element) else { return nil }
        // Marker lengths count each U+FFFC before them, plain offsets do not.
        var objects = [0]
        objects.reserveCapacity(raw.count + 1)
        for unit in raw { objects.append(objects[objects.count - 1] + (unit == 0xFFFC ? 1 : 0)) }
        var scan = EmptyBlockScan<AXUIElement>(budget: budget - 2, block: { node in
            let reads = AX.attributes([kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute], of: node)
            guard (0..<3).allSatisfy({ absentOrRead(reads, $0) }) else { return nil }
            return EmptyBlockScan.Block(role: reads.string(0), subrole: reads.string(1), children: reads.elements(2) ?? [])
        }, offset: { node, end in
            guard let length = AX.markerLength(from: start, to: node, end: end, in: element),
                  objects.indices.contains(length) else { return nil }
            return length - objects[length]
        })
        return scan.run(blocks: blocks, plain: plain).map { ($0, scan.reads + 2) }
    }

    /// A slot that read, or whose attribute the element lacks; any other failure is a failed read.
    private static func absentOrRead(_ reads: AX.AttributeBatch, _ index: Int) -> Bool {
        guard let error = reads.error(index) else { return true }
        return error == .noValue || error == .attributeUnsupported
    }
}
