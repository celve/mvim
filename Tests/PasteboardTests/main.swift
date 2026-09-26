import AppKit

// On a private named pasteboard, never the user's; a child process of this binary plays the lazy owner and the slow target.

typealias Flavours = [[(NSPasteboard.PasteboardType, Data)]]

let privateType = NSPasteboard.PasteboardType("com.loom.mvim.test.private")

func dump(_ pasteboard: NSPasteboard) -> Flavours {
    (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
}

func same(_ a: Flavours, _ b: Flavours) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { x, y in
        x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

func describe(_ flavours: Flavours) -> String {
    flavours.map { "[" + $0.map { "\($0.0.rawValue):\($0.1.count)" }.joined(separator: " ") + "]" }.joined(separator: " ")
}

func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func child(_ arguments: [String]) -> (Process, Pipe) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    process.standardOutput = output
    try! process.run()
    return (process, output)
}

func line(from pipe: Pipe) -> String {
    var data = Data()
    while !data.contains(UInt8(ascii: "\n")) {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        data += chunk
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

final class LazyOwner: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .string {
            item.setString("provided lazily", forType: .string)
        } else {
            item.setData(Data([7, 7, 7]), forType: type)
        }
    }
}

let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "lazy-owner" {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(arguments[2]))
    let owner = LazyOwner()
    let item = NSPasteboardItem()
    item.setDataProvider(owner, forTypes: [.string, privateType])
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
    print("ready")
    fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(30))
    exit(0)
}
if arguments.count > 3, arguments[1] == "reader" {
    Thread.sleep(forTimeInterval: Double(arguments[3])!)
    print(NSPasteboard(name: NSPasteboard.Name(arguments[2])).string(forType: .string) ?? "nil")
    exit(0)
}

@MainActor
func run() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    let image = NSImage(size: NSSize(width: 3, height: 2), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
    let tiff = image.tiffRepresentation!
    let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    let rtf = try! NSAttributedString(string: "rich").data(
        from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    let files = ["one", "two"].map { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mvim-\($0).txt") }

    let fixtures: [(String, () -> Void)] = [
        ("text, RTF and HTML", {
            pasteboard.setString("rich", forType: .string)
            pasteboard.setData(rtf, forType: .rtf)
            pasteboard.setData(Data("<b>rich</b>".utf8), forType: .html)
        }),
        ("image only", {
            pasteboard.setData(tiff, forType: .tiff)
            pasteboard.setData(png, forType: .png)
        }),
        ("two files", { pasteboard.writeObjects(files as [NSURL]) }),
        ("text beside a private item", {
            let text = NSPasteboardItem()
            text.setString("first", forType: .string)
            let other = NSPasteboardItem()
            other.setData(Data([0, 1, 2, 255]), forType: privateType)
            pasteboard.writeObjects([text, other])
        }),
        ("empty", {}),
    ]

    for (name, fill) in fixtures {
        pasteboard.clearContents()
        fill()
        let before = dump(pasteboard)
        let loan = PasteboardLoan(pasteboard)
        loan.put("REG")
        let lent = dump(pasteboard)
        precondition(lent.count == 1 && pasteboard.string(forType: .string) == "REG"
                     && lent[0].map(\.0) == [.string, PasteboardLoan.transient], "\(name) lent: \(describe(lent))")
        loan.restore()
        precondition(same(dump(pasteboard), before), "\(name): \(describe(before)) came back \(describe(dump(pasteboard)))")

        loan.put("A")
        loan.put("B")
        precondition(pasteboard.string(forType: .string) == "B")
        loan.restore()
        precondition(same(dump(pasteboard), before), "\(name) after two puts: \(describe(dump(pasteboard)))")
    }

    let (owner, ready) = child(["lazy-owner", pasteboard.name.rawValue])
    precondition(line(from: ready) == "ready")
    let loan = PasteboardLoan(pasteboard)
    loan.put("REG")
    owner.terminate()
    owner.waitUntilExit()
    loan.restore()
    let provided = dump(pasteboard)
    precondition(pasteboard.string(forType: .string) == "provided lazily" && provided.count == 1
                 && provided[0].contains { $0.0 == privateType && $0.1 == Data([7, 7, 7]) }, describe(provided))

    // A newer writer wins, and the next put saves what it wrote.
    pasteboard.clearContents()
    pasteboard.setString("mine", forType: .string)
    loan.put("REG")
    pasteboard.clearContents()
    pasteboard.setString("cut", forType: .string)
    let cut = pasteboard.changeCount
    loan.restore()
    precondition(pasteboard.changeCount == cut && pasteboard.string(forType: .string) == "cut")
    loan.put("REG")
    loan.restore()
    precondition(pasteboard.string(forType: .string) == "cut")
    loan.restore()
    precondition(pasteboard.changeCount == cut + 2, "a loan with nothing borrowed writes nothing")

    pasteboard.clearContents()
    pasteboard.setString("mine", forType: .string)
    loan.put("REG")
    loan.landed()
    spin(0.05)
    precondition(pasteboard.string(forType: .string) == "mine", "a landed paste is given back on the next turn")

    loan.put("REG")
    spin(0.6)
    precondition(pasteboard.string(forType: .string) == "REG", "an unconfirmed paste stays up")
    loan.put("REG2")
    spin(0.5)
    precondition(pasteboard.string(forType: .string) == "REG2", "an earlier put's give-back is stale")
    spin(0.6)
    precondition(pasteboard.string(forType: .string) == "mine", "the unconfirmed hold ends")

    // The target reads the paste 600 ms late, where a 200 ms give-back handed it the user's text.
    loan.put("REG")
    let (reader, read) = child(["reader", pasteboard.name.rawValue, "0.6"])
    while reader.isRunning { spin(0.02) }
    precondition(line(from: read) == "REG", "a slow target reads the register")
    spin(0.5)
    precondition(pasteboard.string(forType: .string) == "mine")
}

MainActor.assumeIsolated { run() }
print("Pasteboard tests passed")
