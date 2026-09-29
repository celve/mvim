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

let surface = Surface(bundleID: "com.example.app", role: "AXTextArea")
let rung = surface.roleRung!
let versions = Versions(app: "1.2")

func resolved(_ contents: Beliefs.Contents, chromium: Bool = false) -> ResolvedBeliefs {
    contents.store.resolve(rungs: surface.rungs, rung: rung, versions: versions, chromium: chromium, children: true,
                           userPinsOffsets: false)
}

func entry(_ contents: Beliefs.Contents, _ capability: Capability, chromium: Bool = false) -> CapabilityReport.Entry? {
    let config = CapabilityConfig.resolveAll(surface, capabilities: [capability.rawValue], overrides: contents.overrides)
    let choice = config[capability.rawValue]!.override.map { $0 == .on ? ConfigChoice.Override.on : .off }
    let probed = CapabilityProfile(available: Set(Capability.allCases))
    return CapabilityResolver.resolve(probed: probed, config: [capability: ConfigChoice(override: choice)],
                                      beliefs: resolved(contents, chromium: chromium)).report.entries[capability]
}

func belief(_ question: String, _ answer: String, version: String = "1.2", _ more: String = "") -> String {
    #"{"rung": "\#(rung)", "question": "\#(question)", "answer": "\#(answer)", "appVersion": "\#(version)", "provenance": {}\#(more)},"#
}

func file(_ beliefs: String..., overrides: String = "") -> String {
    "{\n  \"schema\": 3,\n  \"overrides\": {\(overrides)},\n  \"beliefs\": [\n    "
        + beliefs.joined(separator: "\n    ") + "\n  ]\n}\n"
}

let blank = fresh()
precondition(try! blank.load() == Beliefs.Contents() && (try! blank.read()) == Beliefs.Contents(), "a file to open from the first load")
try! FileManager.default.removeItem(at: blank.url)
precondition(try! blank.load() == Beliefs.Contents() && FileManager.default.fileExists(atPath: blank.url.path))

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
    answer: .value, source: .learned, learned: .value, belief: valued.store.offsetsBelief(at: rung)
), "a Chromium field set to value by hand")
write(file(belief("insertText", "broken", version: "1.1")), to: edited)
precondition(resolved(try! edited.load()).broken.isEmpty, "an app update reopens an edited verdict too")
write(file(belief("insertText", "broken"), overrides: #""com.example.app": {"insertText": "on"}"#), to: edited)
precondition(entry(try! edited.load(), .insertText) == .init(status: .available, source: .probed), "an On in the file beats a belief")
write(file(overrides: #""\#(rung)": {"writeSelection": "off"}, "com.example.app|role:AXTextField": {"writeSelection": "on"}"#), to: edited)
precondition(entry(try! edited.load(), .writeSelection) == .init(status: .unavailable, source: .user))
write(file(belief("fromLaterBuild", "anything"), overrides: #""\#(rung)": {"fromLaterBuild": "off"}"#), to: edited)
precondition((try? edited.load()) != nil, "names this build does not know are kept")

var tally = Tally()
tally.textContent = 2
let full = Beliefs.Contents(overrides: ["com.example.app": ["nativeMotions": "on"]], beliefs: [
    Belief(rung: rung, question: .write(.writeSelection), answer: Belief.broken, judgedUnder: .textContent,
           versions: Versions(app: "1.2", engine: "41.3.0"),
           provenance: Provenance(build: "1.0.0 (812)", learnedAt: "2026-09-28T07:00:00Z", tag: "e3.c7")),
    Belief(rung: rung, question: .offsets, answer: "textContent", versions: versions, tally: tally, anchor: true),
    Belief(rung: rung, question: .unknown("fromLaterBuild"), answer: "x", versions: versions),
])
let saved = fresh()
try! saved.update { $0 = full }
precondition(try! saved.load() == full)
precondition(text(saved).hasSuffix("}\n") && text(saved).contains("\"schema\" : 3"))

var tries = 0
try! saved.update {
    if tries == 0 { write(file(overrides: #""other.app": {"wordKeys": "off"}"#), to: saved) }
    tries += 1
    $0.overrides[rung] = ["insertText": "off"]
}
precondition(tries == 2 && (try! saved.load()).overrides == ["other.app": ["wordKeys": "off"], rung: ["insertText": "off"]],
             "an edit saved between mvim's read and its write is kept")
precondition((try? saved.update {
    tries += 1
    write(file(overrides: #""app\#(tries)": {"wordKeys": "off"}"#), to: saved)
    $0.overrides[rung] = ["insertText": "on"]
}) == nil && (try! saved.load()).overrides == ["app\(tries)": ["wordKeys": "off"]], "a file that keeps changing is left to its writer")

let menu = fresh()
try! menu.update { $0 = full }
try! menu.update {
    $0.overrides = CapabilityConfig.setting(.off, at: rung, on: surface, capability: "readCaret", in: $0.overrides)
    $0.retire(.readCaret, at: rung)
}
let chosen = try! menu.load()
precondition(chosen.overrides == ["com.example.app": ["nativeMotions": "on"], rung: ["readCaret": "off"]])
precondition(chosen.beliefs == [full.beliefs[0], full.beliefs[2]], "Read caret's choice retires the offsets belief")
try! menu.update {
    $0.overrides = CapabilityConfig.setting(nil, at: nil, on: surface, capability: "readCaret", in: $0.overrides)
}
precondition(try! menu.load() == Beliefs.Contents(overrides: full.overrides, beliefs: chosen.beliefs), "Auto revives nothing")
try! menu.update { $0.overrides = CapabilityConfig.clearing(atAndBelow: "com.example.app", on: surface, in: $0.overrides) }
precondition(try! menu.load().overrides.isEmpty)

let retry = fresh()
try! retry.update { $0 = full }
precondition(entry(try! retry.load(), .writeSelection, chromium: true) == .init(status: .unavailable, source: .learned))
try! retry.update { $0.forget([full.beliefs[0]]) }
precondition(try! retry.load() == Beliefs.Contents(overrides: full.overrides, beliefs: [full.beliefs[1], full.beliefs[2]]),
             "Try Again forgets the lesson and makes no choice")
precondition(entry(try! retry.load(), .writeSelection, chromium: true) == .init(status: .available, source: .probed))

for unusable in [
    "{\n  \"schema\": 3,\n  \"overrides\": {},\n  \"beliefs\": [\n    {\"rung\": x}\n  ]\n}\n",
    #"{"schema": 4, "overrides": {}, "beliefs": []}"#,
    #"{"schema": 3, "beliefs": []}"#,
    file(#"{"rung": "r", "question": "offsets", "answer": "value"},"#),
    file(belief("offsets", "value", #", "judgedUnder": "valu""#)),
    file(belief("offsets", "textContet")),
    file(belief("insertText", "works")),
    file(overrides: #""\#(rung)": {"insertText": "Off"}"#),
] {
    let broken = fresh()
    try! broken.update { $0 = full }
    write(unusable, to: broken)
    precondition((try? broken.load()) == nil && (try? broken.update { $0 = Beliefs.Contents() }) == nil)
    precondition(text(broken) == unusable, "a broken edit waits for the user")
    let fallback = broken.current()
    precondition(fallback.contents == full && fallback.problem != nil, "the last version that read stays in force")
    precondition(Beliefs(url: broken.url, defaults: broken.defaults).current().contents == full, "and survives a relaunch")
}
let occupied = fresh()
try! FileManager.default.createDirectory(at: occupied.url, withIntermediateDirectories: true)
precondition((try? occupied.load()) == nil && (try? occupied.update { $0 = full }) == nil)

let storeJSON = String(decoding: try! JSONEncoder().encode(full.store), as: UTF8.self)
let moved = fresh()
moved.defaults.set(storeJSON, forKey: Beliefs.beliefsKey)
moved.defaults.set(full.overrides, forKey: Beliefs.overridesKey)
precondition(try! moved.load() == full && (try! moved.read()) == full)
precondition(moved.defaults.string(forKey: Beliefs.beliefsKey) == nil && moved.defaults.object(forKey: Beliefs.overridesKey) == nil)
let stuck = fresh()
write("", to: Beliefs(url: stuck.url.deletingLastPathComponent(), defaults: stuck.defaults))
stuck.defaults.set(storeJSON, forKey: Beliefs.beliefsKey)
stuck.defaults.set(full.overrides, forKey: Beliefs.overridesKey)
precondition((try? stuck.load()) == nil, "no file and none can be written is not a usable one")
precondition(stuck.defaults.string(forKey: Beliefs.beliefsKey) == storeJSON && stuck.defaults.object(forKey: Beliefs.overridesKey) != nil)
precondition(stuck.current().contents == full && stuck.current().problem != nil)
let upgraded = fresh()
write(file(overrides: #""com.example.app": {"insertText": "on"}"#), to: upgraded)
upgraded.defaults.set(storeJSON, forKey: Beliefs.beliefsKey)
upgraded.defaults.set(full.overrides, forKey: Beliefs.overridesKey)
_ = try! upgraded.load()
precondition(upgraded.defaults.object(forKey: Beliefs.beliefsKey) == nil && upgraded.defaults.object(forKey: Beliefs.overridesKey) == nil)
try! FileManager.default.removeItem(at: upgraded.url)
precondition(try! upgraded.load() == Beliefs.Contents(), "deleting the file drops every choice, the stale defaults' too")

let legacy = fresh()
legacy.defaults.set(#"{"schema":2,"records":[{"rung":"\#(rung)","version":"1.2","capability":"writeSelection"}]}"#,
                    forKey: Beliefs.legacyKey)
let demotions = Beliefs.Contents(beliefs: BeliefStore(demotions: [(rung, "1.2", "writeSelection")]).beliefs)
precondition(try! legacy.load() == demotions && (try! legacy.read()) == demotions)
precondition(legacy.defaults.string(forKey: Beliefs.legacyKey) == nil)

let garbled = fresh()
garbled.defaults.set("{", forKey: Beliefs.beliefsKey)
precondition(try! garbled.load() == Beliefs.Contents() && garbled.defaults.string(forKey: Beliefs.beliefsKey) == nil)

let linked = fresh()
let elsewhere = root.appending(path: "dotfiles/beliefs.json")
try! FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: linked.url.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: elsewhere)
write(file(), to: Beliefs(url: elsewhere, defaults: linked.defaults))
try! linked.update { $0 = full }
precondition((try? FileManager.default.destinationOfSymbolicLink(atPath: linked.url.path)) == elsewhere.path)
precondition(try! Beliefs(url: elsewhere, defaults: linked.defaults).read() == full)

try! FileManager.default.removeItem(at: root)
for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
print("Belief file tests passed")
