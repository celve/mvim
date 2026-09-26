# mvim

System-wide **Vim mode** for macOS — a native SwiftUI **menu bar** app. mvim layers modal
editing (Normal / Insert / Visual, operators, motions, registers, `/` search) over every
text field on the system.

mvim is one half of the former **Loom** app — the other half is **Vibe**, the
voice-dictation app. It was split out of `celve/loom` @ `1a2fcfe`. The Xcode project is
generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and built with `xcodebuild`.

## Requirements

- macOS 14.0 or later
- Xcode 16 or later
- XcodeGen — `brew install xcodegen`

## Build

```sh
make build
```

This generates `mvim.xcodeproj` from `project.yml` and builds the app. The binary lands at:

```
build/Build/Products/Debug/mvim.app
```

### Run

```sh
make run
```

### Release

```sh
make release
```

The Release build is copied to a short, stable path:

```
.release/mvim.app
```

Nothing is launched or installed — open it yourself. `make clean` leaves `.release/`
alone (see [Start at login](#start-at-login)); `make distclean` removes it too. Its build
number is the commit count, which is how [updates](#updates) are ordered.

### Other targets

| Command          | Description                                    |
| ---------------- | ---------------------------------------------- |
| `make gen`       | Generate `mvim.xcodeproj` from `project.yml`   |
| `make build`     | Generate + build a Debug binary                |
| `make run`       | Build, then launch the Debug `mvim.app`        |
| `make test`      | Run the pure Vim engine tests                  |
| `make test-pasteboard` | Test the pasteboard loan on a private pasteboard |
| `make release`   | Build Release, copy it to `.release/mvim.app`  |
| `make dist`      | `release`, then stage its update in `dist/`    |
| `make publish`   | `dist`, then release it on GitHub              |
| `make clean`     | Remove `build/`, `dist/` and the `.xcodeproj`  |
| `make distclean` | `clean`, plus remove `.release/`               |

### Manual invocation

```sh
xcodegen generate
xcodebuild -project mvim.xcodeproj -scheme mvim -configuration Debug \
  -derivedDataPath build build
```

## Project layout

```
mvim/
├── project.yml                 # XcodeGen spec — 2 framework targets + the app
├── Makefile                    # gen / build / run / release / dist / publish / clean / …
├── Info.plist                  # Sparkle's feed and key, merged into the generated plist
├── mvim.entitlements           # intentionally empty — mvim runs non-sandboxed
├── scripts/
│   └── sparkle-release.sh      # stages and publishes an update (make dist / publish)
├── Sources/
│   ├── Core/                   # LoomCore framework — shared, feature-agnostic:
│   │                           #   InputHub (one shared CGEventTap), KeyEvent/Mods/Trigger,
│   │                           #   AX/Clipboard/Synth, Prefs store, LoginItem (start at
│   │                           #   login). NO Keychain in mvim's copy.
│   ├── Vim/                    # LoomVim framework (→ Core) — modal editing:
│   │   ├── Key,Model,Raw,      #   pure engine (no AppKit/AX; `make test` compiles this):
│   │   │   Logical,Physical,   #   the keystroke gate, vocabulary, parsing + key
│   │   │   State,Text,Sim      #   assembly, planners, state + reducer, text math,
│   │   │                       #   simulated host
│   │   └── Runtime/            #   tap routing, AX execution, Controller, Diag
│   └── App/                    # mvim app — composition root: MvimApp (the menu-bar
│                               #   menu, the whole UI), its AppModel, and Updater (Sparkle)
└── Resources/
    └── Assets.xcassets         # App icon + accent color (placeholders)
```

### Modules

`mvim (app) → LoomVim → LoomCore`, one-way and compiler-enforced. The framework names keep
their Loom heritage — they are internal targets, invisible at runtime. Vim's pure engine
(everything under `Sources/Vim` except `Runtime/`) has no AppKit/AX dependency and is
unit-tested standalone via `make test`. Only the app links [Sparkle](https://sparkle-project.org),
pinned to an exact version in `project.yml`.

The generated `mvim.xcodeproj` is intentionally git-ignored — it is a build artifact. Edit
`project.yml` to change build settings, then regenerate.

## Permissions, trust, first launch

mvim needs **Accessibility** (read/drive text fields via AX, post synthesized events) and
**Input Monitoring** (its consuming `CGEventTap`). That is the whole list — by construction
mvim contains **no microphone or keychain code**, its only network traffic is the
[update check](#updates), and its Info.plist carries no microphone usage string. After granting a permission for the first time, relaunch the app —
an already-created event tap cannot retro-enable itself.

### Upgrading from Norm

This app was called **Norm**. The rename moved the bundle identifier from `com.loom.Norm` to
`com.loom.mvim`, and macOS keys the privacy grants, the preferences domain and the login item
on it, so nothing carries across by itself — there is no migration code:

1. **In Norm's menu, switch Start at Login off, then quit Norm.** Two copies would each
   install a consuming event tap and fight over every keystroke. Then delete the old `Norm.app` —
   `.release/Norm.app` survives `make clean`. An item left behind can be removed under System
   Settings → General → Login Items.
2. **Before launching mvim, carry your settings across** — per-app Auto / Off / Force,
   capability overrides, learned priors. They stay in the `com.loom.Norm` domain, which is left
   in place; skip this to start fresh, re-entering policies and overrides from the menu while the
   priors are learned again:

   ```sh
   defaults export com.loom.Norm - | defaults import com.loom.mvim -
   ```

   The import merges: a key both domains hold takes Norm's value, and every other key is kept.
3. **Launch mvim, grant it Accessibility and Input Monitoring**, then relaunch it. Norm's rows in
   System Settings → Privacy & Security (and the combined Loom app's, if still there) are
   orphans — remove them manually.

Diagnostics move with the identifier: logs from before the rename stay under subsystem
`com.loom.Norm`, and the text-recording flag is now `mvimRecordText`. A `sudo log config` you
set for `com.loom.Norm` stays in force on that subsystem: clear it with
`sudo log config --reset --subsystem com.loom.Norm`, then re-apply it to `com.loom.mvim` (see
[Diagnostics](#diagnostics)).

## Start at login

The menu's **Start at Login** toggle registers mvim with `SMAppService.mainApp`, the
API that replaced `SMLoginItemSetEnabled`. The system owns the bit — nothing is
mirrored into `Prefs`, and the menu re-reads the real status every time it opens.
Three consequences worth knowing:

- **It needs a real signature.** `SMAppService` requires a properly code-signed
  bundle and fails with `kSMErrorInvalidSignature` otherwise, so the toggle needs a
  build made with the Apple Development identity — see [Signing](#signing).
- **Registration records the bundle's path.** Register from
  `build/Build/Products/Debug/mvim.app` and a `make clean` strands the login item;
  move the app afterwards and it still points at the old location. `.release/mvim.app`
  is the stable path `make clean` spares — but it still lives inside the repo, so
  `make distclean` or deleting the clone strands the item just the same. Register
  from wherever mvim will actually live.
- **A denial in System Settings is one-way from mvim's side.** Switching the item off
  under System Settings → General → Login Items leaves the status at
  `requiresApproval` — registered but denied — and `register()` cannot clear it. The
  menu shows the toggle unchecked and grows an **Approve mvim in Login Items
  Settings** row.

A login-launched mvim keeps its Accessibility and Input Monitoring grants: same
bundle, same signature.

## Updates

Release builds update themselves with [Sparkle](https://sparkle-project.org) from this
repository's GitHub releases: the feed is the `appcast.xml` attached to the latest one.

- **Sparkle asks first.** On mvim's second launch it asks whether to check once a day, and
  whether to install what it finds without asking. **Check for Updates Automatically** in the
  menu changes the first answer; the checkbox in the update window changes the second.
- **Check for Updates…** checks now. When a daily check finds an update later than right after
  launch, the item reads **Update to mvim X…** instead: a menu-bar app has no window to bring
  forward, so Sparkle would otherwise open its window behind your work.
- **Grants survive an update** because TCC holds them against the app's designated requirement,
  and `make publish` refuses a build that fails the current release's — see below.
- **Debug builds never update.** `project.yml` gives the feed and key to Release only, and a
  build missing either has no update items — as does a Release build made before the key is set.
- **What goes out:** a request to github.com for the feed, and the download when you install.
  Sparkle's anonymous system profiling stays off.

### Publishing an update

Once, on the Mac you will publish from:

1. Run `make release`, which resolves Sparkle, then
   `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`. It keeps a new private key
   in the login keychain and prints the public one: paste that into `SPARKLE_PUBLIC_KEY` in
   `project.yml` and commit it.
2. Back the private key up — `generate_keys -x <file>`, then store the file somewhere safe. Every
   installed copy trusts that key alone; lose it and they can never update again.
3. `gh auth login`: the release is created with the GitHub CLI.

For each release, from a clean checkout of `main` on a Mac holding the signing certificate:

1. Bump `MARKETING_VERSION` in `project.yml` and merge it.
2. `make dist` stages `dist/mvim-<version>.zip`, its notes (GitHub's, from the merged pull
   requests) and `appcast.xml` without publishing anything. Allow the keychain prompt the first
   time.
3. `make publish` stages the same, then creates release `v<version>` holding the zip and the
   appcast. Installed copies find it at their next check.

`make publish` refuses to release when:

- the app is ad-hoc signed, or does not satisfy the designated requirement of the latest
  release's app — TCC holds Accessibility and Input Monitoring against that requirement, so every
  install would lose both. An Apple Development requirement names the certificate's holder, so
  publish from the same person's certificate; for a deliberate change, such as moving to
  Developer ID, `SPARKLE_NEW_IDENTITY=1 make publish` publishes anyway;
- the appcast item came out unsigned — the key is not the one `SUPublicEDKey` names — or
  `SUPublicEDKey` is not the latest release's: installs verify with the key they shipped with, so
  either way every install would reject the update. On a new Mac, import the original key with
  `generate_keys -f <backup>`; never paste a freshly generated one into `project.yml`;
- the tree has uncommitted changes, `HEAD` is not on `main`, `v<version>` exists, or the build
  number does not exceed the one the latest release offers, which installs would ignore;
- GitHub cannot answer any of those questions: a failed read refuses rather than guesses.

`SPARKLE_KEY_FILE=<file>` signs with a key file instead of the keychain.

Releases are not notarized: they carry the Apple Development signature, so a copy downloaded from
GitHub in a browser opens only after **Open Anyway** in System Settings → Privacy & Security.
Updates Sparkle installs are not quarantined. Notarizing takes a `Developer ID Application`
certificate, the hardened runtime and `notarytool`.

## Diagnostics

mvim records one line per **command decision** to `os_log`, under subsystem
`com.loom.mvim`. The unit is the decision, not the keystroke: what a reader wants back is
*"the engine believed X about this field, and X was false"*.

```sh
log show --predicate 'subsystem == "com.loom.mvim"' --last 1h --info --debug
log collect --last 2h --output mvim.logarchive     # to send somewhere
```

A command that did **not** fully succeed logs at `.default` and is persisted to disk for
free, surviving the quit a stranded user is about to perform. A clean command logs at
`.debug`, which is off until asked for:

```sh
sudo log config --subsystem com.loom.mvim --mode "level:debug,persist:debug"
sudo log config --subsystem com.loom.mvim --mode "level:default"    # off again — it is sticky
```

The renderers live on the engine types themselves, under a `// MARK: - Recorder` banner in
each type's file; `grep -rn '// MARK: - Recorder' Sources/Vim` is the index.

Five categories: `bind` (a field became vim's, with its whole capability resolution),
`cmd` (the anchor event), `settle` (a prediction the field did not meet, and what it
answered instead), `learn` (a demotion committed, or the reason one was not), `gate` (an
element that did not become a binding). Every line carries `e<epoch>.c<seq>` — the binding
and the command — so `grep -E 'e12\b'` is the whole join. A bind line is `e12 …` and a
command line `e12.c47 …`; the word boundary catches both and keeps `e120` out.

Reading a `cmd` line, `steps=` is the ordered, payload-free plan, one character per step:

```
W setSelection   R replaceSelection   P press (P3 = three times)   T typeText
X clipboardCut   Y clipboardCopy      V clipboardInsert            G captureSelectedText
! settle         ? softSettle         C commit                     B bell
```

Order is the diagnostic — a `!` directly after a counted arrow `P` is a hard settle verifying
a blind keypress, which can never name the capability it failed, so it rings without teaching
the learner anything. A `!` after a native key names that key, and a failure blames it
(`fail=lineStartKey`) when a caret key left a selection, or, outside web content, when the field
still reads as it did before the key although the key had somewhere to go. A landing somewhere
else aborts without learning.

When keys made the selection an edit is about to delete or type over, the edit first checks
the selected text: `ciw` without AX selection writes is `P2P5!!P?CCC`, where the second `!`
waits for `AXSelectedText` to equal the text the plan selected from `AXValue`, not counting the
U+FFFC Chromium writes into it for each icon or other element with no text. Chromium's
rich-text fields misread the caret, so the keys can select other text while every offset reads
back as planned. A failed check presses ← to drop that selection and leaves mvim in Normal
mode. Its `settle` line adds `text=(N)`, a length and never the text, on both sides; a `FAIL`
whose `sel` and `len` agree failed on the text.

`abort@N` names the step that ended the run, and the `C`s behind it did **not** all die with
it: a commit carrying residency still lands (`VimEffect.survivesAbort`), which is why an
aborted line can read `ok=0` and `mode=normal→insert` together. Before that, the mode change
sat behind the settle and a lying field decided which mode mvim was in — `mode=normal→normal`
on a `steps=W!R!CCC abort@3` line is the signature of that bug.

A Chromium rich-text field (a contenteditable in Chrome, Dia or an Electron app; its bind
line says `chromium=1`) names its selection in text content: `AXValue` without the `\n`
Chromium generates where a paragraph starts. mvim plans in `AXValue` offsets and converts at
the field's edge, so a `settle` line's `want` and `got` are the field's own offsets, behind the
planner's by the paragraph breaks before them. Where one field offset is both a paragraph's end
and the next one's start, `edge=end` or `edge=start` says which the settle waited for.

A web field finds its site by walking up to the page that contains it. When the walk names no
site, the field keys at the app rung alongside the app's own chrome, and a `gate` line says
why:

```
e12 surface origin=nil web=1 role=AXTextArea stop=orphan@9 axerror=-25204 ms=151
```

`stop=` is where the walk ended and `@` the element it stopped at, 0 being the field itself:
`noURL` (the page exposed no `AXURL`), `hostless` (its URL names no site; `scheme=` says which,
such as `file`), `window` or `application` (no page above the field at all), `orphan` (no
parent to follow; `axerror=` is the read's `AXError`, `-25204` when the app did not answer in
time or at all, `nil` when it answered with no parent), `hopCap` (the element cap reached
without a page), `budget` (the walk's time budget ran out). For those last two, `@` is
the first element the walk did not read. A walk that found its site logs `stop=site@N` at
`.debug`.

**Text is not recorded**, and that is a unit test rather than a convention. `keys=` shows
what you typed only where it is provably free of variable, data-bearing input — no operand,
no register, no digit; otherwise it shows the command's shape and a length. (`ciw` is
user-supplied too; what makes it safe is that it comes from a finite grammar.) `d/needle<CR>`
becomes `op(delete,search)…(12)`, `3dd` becomes `op(delete,line)…(3)`, and even `0` becomes
`motion(lineStart)…(1)`, because the digit test scans the string being written rather than
the parse — which is lossy and drops a count outright when the command is still incomplete.

The rule is not "syntax is safe, content is not". It is that when mvim's mode tracking is
wrong — the bug this exists to find — you believe you are typing and every keystroke parses
as a Normal-mode command, so an operand or a count *is* a letter of your prose. `4111…w` is
a card number with a `w` on the end. The opt-in for recording content, which the menu does
not offer and every `bind` line announces while it is on:

```sh
defaults write com.loom.mvim mvimRecordText -bool YES
defaults delete com.loom.mvim mvimRecordText
```

**Both edges need a relaunch.** The flag is read once per process, deliberately — re-reading
it per line would put a `UserDefaults` lookup on the command path — so `defaults delete`
does not stop an mvim that is already running.

## Native keys

When a field can be read but not written, mvim moves by line and document with the standard
Cocoa bindings instead of counting arrow presses: ⌃A/⌃E to the start and end of the caret's
paragraph, which is mvim's line, ⇧⌃A/⇧⌃E to select there, and ⌘↑/⌘↓ (⇧ to select) for the
document. `dd` is ⌃A, ⇧⌃E, ⇧→; `j` is ⌃E, → and then the column counted on the new line; `0`,
`$`, `gg`, `G`, `D`, `C`, `cc`, `yy`, `o`, `O`, `J` and linewise puts follow the same pattern.
`x` and `X` still select one character and check it before deleting, because ⌦ and ⌫ would
delete first and join lines at a line end.

Each key is a row in the Capabilities menu — **Line start key (⌃A)**, **Line end key (⌃E)**,
**Document start key (⌘↑)**, **Document end key (⌘↓)** — claimed for every field whose text
and caret mvim can read. A key that lands anywhere but where it
should, including a caret key that leaves a selection (as a select-all binding would) or a key that does
nothing where it had somewhere to go, is learned off for that surface like a write that lies, and mvim
counts arrows there again; switch it back on from the menu. In Chromium's rich text a key that lands
somewhere else only aborts the command, because one paragraph can be several `AXValue` lines there (a
mention chip) and a working key lands off the model's line; turn such a key off from the menu.

Chromium's rich text (Dia, Chrome, Electron apps such as Linear) reports the caret without the
paragraph breaks before it (LIN-1533); mvim reads it through text markers and puts the breaks back
(LIN-1564), and where that fails the caret is unknown and the command goes blind. Keys are pressed
even where a command has nothing to select or `j`/`k` stays on its line, so a settle still checks
the caret the command starts from. An empty paragraph can be missing from `AXValue`, and a caret
in one reads as its neighbour's, so a key pressed from a caret whose marker sits on an empty
paragraph is not blamed for seeming to do nothing. In such a field a yank within one line takes its register from
the text the field selected.

`o` and `O` paste their newline in web content: typed, it makes no paragraph in Chromium's rich
text, and ⏎ would send a chat message. Chromium leaves the new empty paragraph out of `AXValue`
until it holds text, so the settles after it do not check the length.

Such a paste, like any register pasted where the field takes no AX insertion, borrows the
pasteboard. mvim saves every item in every type it holds, puts the text up for one ⌘V (marked
`org.nspasteboard.TransientType`, so clipboard histories that honour it skip it), and puts the
rest back as soon as a settle sees the paste land. Nothing else says when the app has read it,
so a paste no settle confirmed, as with `o` above, stays up for a second. Your own ⌘V, and a
paste of `+`, `*` or a blind cut's register, gets your contents back first, and a copy or cut
made meanwhile is newer and is kept.

## Native word, paragraph and page keys

Off by default. **Capabilities in <app> › App's word, paragraph & page keys** turns it on for one
field, fields like it, a site or the whole app. With it on, mvim presses the app's own keys
instead of counting arrows or ringing, and the app decides where they land:

| Vim | Keys |
|---|---|
| `w` `e` / `b` | ⌥→ / ⌥← |
| `iw` (`ciw` `diw` `yiw` `viw`) | ⌥→ ⌥← to the word's start, then ⌥→ ⇧⌥← over it, then ⌘X or ⌘C |
| `dw` `de` `cw` `ce` `yw` / `db` `cb` `yb` | ⇧⌥→ / ⇧⌥←, then ⌘X or ⌘C. From a word's edge, and in Chinese, Japanese or Thai, ⌥→ and ⌥← go out and back first |
| `{` `}` | ⌥↑ / ⌥↓ |
| `gj` `gk` | ↓ / ↑ |
| `j` `k` | ↓ / ↑, only where ⌃E/⌃A are demoted and mvim cannot land them on a line |
| `^F` `^B` | ⌥PgDn / ⌥PgUp. Without the option, ⌃F and ⌃B stay the app's |

- **Where it applies.** Words switch only in fields mvim can read but not select in, such as
  Chromium and Electron editors. A field that sets its selection exactly keeps vim's words; the
  paragraph, row and page keys work in every field.
- **`j` and `k`** keep moving by line wherever mvim can land them on one: exact writes, or the
  ⌃E/⌃A hops in a field it reads but cannot select in. Only where those keys are demoted do they
  move by screen row.
- **What changes.** The semantics are the app's, not vim's:
  - words skip runs of punctuation and split Chinese and Japanese by dictionary;
  - ⌥→ stops at a word's end, so `w` lands where `e` does, and `dw` leaves the blank after the word;
  - ⌥↑ and ⌥↓ go to a paragraph's start and end, not to blank lines;
  - `ciw` on a blank selects the word before it, and rings where no word ends there.
- **What stays vim's.** `aw`, counted `iw`, `W` `B` `E` `ge`, and `{` `}` `gj` `^F` as operator
  targets or in Visual mode are unchanged.
- **Checks.** Where mvim can read the caret, each landing is checked against the caret the key
  started from. A word selection must be exactly what ⌥← and ⌥→ delimited or, mid-word, what the
  text says is left of the word; where neither can be known, as inside `foo,bar`, the command
  rings. If a key leaves the field unmoved when it should have moved, or selects more than that,
  it is demoted on that surface: **Word keys (⌥← ⌥→)** or **Paragraph keys (⌥↑ ⌥↓)** then reads `✗ learned`. Words go
  back to counting and paragraphs to ringing until you override it or the app updates.

## Running alongside Vibe

- **`SynthTag.magic` is a cross-app ABI.** Both apps tag their synthesized CGEvents with the
  same magic (`0x4C4F_4F4D`, in each repo's `Sources/Core/Synth.swift`) and bypass tagged
  events before any handler runs. mvim's consuming tap must bypass Vibe's synthesized
  typing — otherwise vim Normal mode would consume a transcript as commands. **Never change
  the magic in one app without the other.**
- **Bare-modifier-tap triggers in Vibe can false-fire around vim.** Both apps install
  head-insert event taps; their relative order depends on launch order. When mvim consumes a
  key-down (Normal mode), Vibe's tap never observes it — e.g. vim consuming `⌃[` makes the
  surrounding `⌃` press look like a clean bare tap. Prefer Vibe's default `⌃⌥D` combo (a
  Carbon hotkey — no tap at all), an `Fn`/🌐 tap, or a double-tap. This is a documented
  limitation; the apps deliberately share no IPC.
- Clipboard transactions are serialized per-process only. A simultaneous mvim register paste
  and Vibe insertion fallback could interleave in principle; humanly this does not occur.

## Signing

The project signs with a stable **Apple Development** identity (`CODE_SIGN_STYLE: Automatic`,
team in `project.yml`) so the Accessibility / Input Monitoring grants persist across
rebuilds — an ad-hoc signature would change every build and macOS would revoke the grants
each time. To build under a different team, change `DEVELOPMENT_TEAM` in `project.yml`.

## License

Copyright © 2026 Linyu Wu

mvim is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE) for
the full terms.

Release builds embed [Sparkle](https://sparkle-project.org), which carries its own MIT license.
