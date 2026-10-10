import ApplicationServices
import Core

/// Text a page generates in a Chromium field, read over AX (LIN-1930); `GeneratedTextScan` has the rules.
extension Snapshotter {
    /// The field shows nothing but its page's generated text, such as an empty editor's placeholder; a failed read says no.
    static func showsOnlyGeneratedText(_ element: AXUIElement, roots: [AXUIElement]? = nil, value: String? = nil) -> Bool {
        guard let roots = roots ?? AX.children(of: element), !roots.isEmpty else { return false }
        var scan = GeneratedTextScan<AXUIElement>(budget: GeneratedText.readBudget) { node in
            let reads = AX.attributes(
                [kAXRoleAttribute, AX.chromiumNodeIDAttribute, kAXValueAttribute, kAXChildrenAttribute], of: node
            )
            guard reads.string(0) != nil, FieldTree.absentOrRead(reads, 3) else { return nil }
            // Chromium answers its node id as a string.
            return GeneratedTextScan.Read(
                role: reads.string(0), id: reads.string(1).flatMap { Int($0) }, value: reads.string(2),
                children: reads.elements(3) ?? []
            )
        }
        guard let texts = scan.run(roots: roots), let value = value ?? AX.value(of: element) else { return false }
        return GeneratedText.fills(value, with: texts)
    }
}
