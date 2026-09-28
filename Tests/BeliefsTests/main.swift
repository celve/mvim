import Foundation

// Temporary directories and private defaults suites, never the user's.

let root = FileManager.default.temporaryDirectory.appending(path: "mvim-beliefs-test-\(getpid())")
var suites: [String] = []

func fresh() -> Beliefs {
    let suite = "com.loom.mvim.test.beliefs.\(getpid()).\(suites.count)"
    suites.append(suite)
    return Beliefs(url: root.appending(path: "\(suites.count)/mvim/beliefs.json"), defaults: UserDefaults(suiteName: suite)!)
}

func text(_ file: Beliefs) -> String {
    (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
}

func write(_ text: String, to file: Beliefs) {
    try! FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: file.url, atomically: true, encoding: .utf8)
}

let rung = "com.example.app|role:AXTextArea"
let versions = Versions(app: "1.2")

func resolved(_ store: BeliefStore, chromium: Bool = false) -> ResolvedBeliefs {
    store.resolve(rungs: [rung, "com.example.app"], rung: rung, versions: versions, chromium: chromium, children: true,
                  userPinsOffsets: false)
}

func entry(_ store: BeliefStore, _ capability: Capability, chromium: Bool = false) -> CapabilityReport.Entry? {
    let probed = CapabilityProfile(available: Set(Capability.allCases))
    return CapabilityResolver.resolve(probed: probed, config: [:], beliefs: resolved(store, chromium: chromium))
        .report.entries[capability]
}

func belief(_ question: String, _ answer: String, version: String = "1.2", _ more: String = "") -> String {
    #"{"rung": "\#(rung)", "question": "\#(question)", "answer": "\#(answer)", "appVersion": "\#(version)", "provenance": {}\#(more)},"#
}

func file(_ beliefs: String...) -> String {
    "{\n  \"schema\": 3,\n  \"beliefs\": [\n    " + beliefs.joined(separator: "\n    ") + "\n  ]\n}\n"
}

let blank = fresh()
precondition(try! blank.load() == BeliefStore() && (try! blank.read()) == BeliefStore(), "a file to open from the first load")
try! FileManager.default.removeItem(at: blank.url)
precondition(try! blank.load() == BeliefStore() && FileManager.default.fileExists(atPath: blank.url.path))

let edited = fresh()
let handWritten = file(belief("insertText", "broken"))
write(handWritten, to: edited)
let hand = try! edited.load()
precondition(resolved(hand).broken == [.insertText] && entry(hand, .insertText) == .init(status: .unavailable, source: .learned))
precondition(text(edited) == handWritten, "reading leaves the user's text alone")
precondition(resolved(hand, chromium: true).broken.isEmpty, "judged under value, so reopened where Chromium counts textContent")
write(file(belief("insertText", "broken", #", "judgedUnder": "textContent""#)), to: edited)
precondition(entry(try! edited.load(), .insertText, chromium: true) == .init(status: .unavailable, source: .learned))
write(file(belief("offsets", "untrusted")), to: edited)
let untrusted = try! edited.load()
precondition(entry(untrusted, .insertText) == .init(status: .available, source: .probed))
precondition(resolved(untrusted, chromium: true).readModel.answer == .untrusted
    && entry(untrusted, .readCaret, chromium: true) == .init(status: .unavailable, source: .learned))
write(file(belief("offsets", "value")), to: edited)
let valued = try! edited.load()
precondition(resolved(valued, chromium: true).readModel == ReadModel(
    answer: .value, source: .learned, learned: .value, belief: valued.offsetsBelief(at: rung)
), "a Chromium field set to value by hand")
write(file(belief("insertText", "broken", version: "1.1")), to: edited)
precondition(resolved(try! edited.load()).broken.isEmpty, "an app update reopens an edited verdict too")

var tally = Tally()
tally.textContent = 2
let full = BeliefStore(beliefs: [
    Belief(rung: rung, question: .write(.writeSelection), answer: Belief.broken, judgedUnder: .textContent,
           versions: Versions(app: "1.2", engine: "41.3.0"),
           provenance: Provenance(build: "1.0.0 (812)", learnedAt: "2026-09-28T07:00:00Z", tag: "e3.c7")),
    Belief(rung: rung, question: .offsets, answer: "textContent", versions: versions, tally: tally, anchor: true),
    Belief(rung: rung, question: .unknown("fromLaterBuild"), answer: "x", versions: versions),
])
let saved = fresh()
try! saved.save(full)
precondition(try! saved.load() == full)
precondition(text(saved).hasSuffix("}\n") && text(saved).contains("\"schema\" : 3"))
try! saved.forget(.write(.writeSelection), at: rung)
precondition(try! saved.load().beliefs == Array(full.beliefs.dropFirst()))

for unreadable in [
    "{\n  \"schema\": 3,\n  \"beliefs\": [\n    {\"rung\": x}\n  ]\n}\n",
    "{\"schema\": 4, \"beliefs\": []}",
    #"{"schema": 3, "beliefs": [{"rung": "r", "question": "offsets", "answer": "value"}]}"#,
    #"{"schema": 3, "beliefs": [{"rung": "r", "question": "offsets", "answer": "value", "appVersion": "1", "provenance": {}, "judgedUnder": "valu"}]}"#,
] {
    let broken = fresh()
    write(unreadable, to: broken)
    precondition((try? broken.load()) == nil && (try? broken.save(full)) == nil && (try? broken.forget(.offsets, at: rung)) == nil)
    precondition(text(broken) == unreadable, "a broken edit waits for the user")
}
let occupied = fresh()
try! FileManager.default.createDirectory(at: occupied.url, withIntermediateDirectories: true)
precondition((try? occupied.load()) == nil && (try? occupied.save(full)) == nil)

let fullJSON = String(decoding: try! JSONEncoder().encode(full), as: UTF8.self)
let moved = fresh()
moved.defaults.set(fullJSON, forKey: Beliefs.defaultsKey)
precondition(try! moved.load() == full && (try! moved.read()) == full)
precondition(moved.defaults.string(forKey: Beliefs.defaultsKey) == nil)
let stuck = fresh()
write("", to: Beliefs(url: stuck.url.deletingLastPathComponent(), defaults: stuck.defaults))
stuck.defaults.set(fullJSON, forKey: Beliefs.defaultsKey)
precondition(try! stuck.load() == full && stuck.defaults.string(forKey: Beliefs.defaultsKey) == fullJSON, "kept until written")

let legacy = fresh()
legacy.defaults.set(#"{"schema":2,"records":[{"rung":"\#(rung)","version":"1.2","capability":"writeSelection"}]}"#,
                    forKey: Beliefs.legacyKey)
let demotions = BeliefStore(demotions: [(rung, "1.2", "writeSelection")])
precondition(try! legacy.load() == demotions && (try! legacy.read()) == demotions)
precondition(legacy.defaults.string(forKey: Beliefs.legacyKey) == nil)

let garbled = fresh()
garbled.defaults.set("{", forKey: Beliefs.defaultsKey)
precondition(try! garbled.load() == BeliefStore() && garbled.defaults.string(forKey: Beliefs.defaultsKey) == nil)

let linked = fresh()
let elsewhere = root.appending(path: "dotfiles/beliefs.json")
try! FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: linked.url.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: elsewhere)
write(file(), to: Beliefs(url: elsewhere, defaults: linked.defaults))
try! linked.save(full)
precondition((try? FileManager.default.destinationOfSymbolicLink(atPath: linked.url.path)) == elsewhere.path)
precondition(try! Beliefs(url: elsewhere, defaults: linked.defaults).read() == full)

try! FileManager.default.removeItem(at: root)
for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
print("Belief file tests passed")
