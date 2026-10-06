# mvim reference

The detail behind the [README](../README.md): building mvim from source, signing and releasing it, reading
its log, and how it works in browsers and Electron apps.

- **Build and release:** [Building from source](#building-from-source) · [Make targets](#make-targets) ·
  [Project layout](#project-layout) · [Modules](#modules) · [Signing](#signing) ·
  [Start at login](#start-at-login) · [Updates](#updates) · [Publishing an update](#publishing-an-update)
- **How it works:** [Diagnostics](#diagnostics) · [Browsers and Electron apps](#browsers-and-electron-apps) ·
  [Native keys](#native-keys) · [Learned beliefs](#learned-beliefs) · [The beliefs file](#the-beliefs-file) ·
  [Native word, paragraph and page keys](#native-word-paragraph-and-page-keys) ·
  [Synthesized events](#synthesized-events)

## Building from source

To build from source, you need Xcode 26 or later (the full app, not only its command-line tools),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.1 or later (`brew install xcodegen`), and an
**Apple Development** signing certificate, which Xcode → Settings → Accounts → Manage Certificates…
creates.

1. Clone this repository and find your certificate's full name, the quoted text this prints. macOS
   keeps mvim's permissions only while its signature stays the same, and an ad-hoc signature changes
   with every build ([Signing](#signing)).

   ```sh
   security find-identity -v -p codesigning
   ```

2. Build it under that name, as `make release` alone asks for the Developer ID certificate that
   releases carry. Then copy it to where it will live, since [Start at Login](#start-at-login)
   remembers the path:

   ```sh
   make release SIGN="Apple Development: Your Name (XXXXXXXXXX)"
   rm -rf /Applications/mvim.app && ditto .release/mvim.app /Applications/mvim.app
   open /Applications/mvim.app
   ```

3. Grant the permissions and open mvim again, as in the README's [Install](../README.md#install) from
   step 2.

To update a build from source, quit mvim, run `git pull --autostash` and the same `make release`,
and copy the app again; the permissions carry over while the same identity signs it.

### Updating across the identifier change

mvim's identifier was `com.loom.mvim` until it became
`io.github.celve.mvim`, and to macOS the two are different apps: the permissions, the settings and
the login item stay with the old one. If this prints `com.loom.mvim`, update this way once:

```sh
defaults read /Applications/mvim.app/Contents/Info CFBundleIdentifier
```

1. Switch **Start at Login** off, and wait until its checkmark clears: it switches in the background.
2. Quit mvim, and Vibe too if you run it (step 6 says why).
3. Remove mvim from Accessibility and Input Monitoring in System Settings → Privacy & Security.
4. Carry the settings over:

   ```sh
   defaults export com.loom.mvim - | defaults import io.github.celve.mvim -
   ```

5. Update as above, open mvim and grant both permissions as on a first install. The beliefs file
   carries over as it is, and **Start at Login** can go back on.
6. If you run Vibe, rebuild it from a checkout whose `SynthTag.magic` is `0x4345_4C56`, as mvim's now
   is ([Synthesized events](#synthesized-events)), before opening it again. An mvim and a Vibe with
   different tags each take the other's typing for yours, so Normal mode would run a dictated
   transcript as commands.

## Make targets

The Xcode project is generated from [`project.yml`](../project.yml) by XcodeGen and built with
`xcodebuild`. `mvim.xcodeproj` is git-ignored: edit `project.yml`, then regenerate.

| Command          | Description                                                          |
| ---------------- | -------------------------------------------------------------------- |
| `make gen`       | Generate `mvim.xcodeproj` from `project.yml`                         |
| `make build`     | Generate, then build Debug to `build/Build/Products/Debug/mvim.app`  |
| `make run`       | Build, then launch the Debug `mvim.app`                              |
| `make test`      | Run the pure engine's tests: no Xcode project, no permissions        |
| `make test-pasteboard` | Run the pasteboard loan's tests on a private pasteboard: no permissions |
| `make test-beliefs` | Run the beliefs file's tests in a temporary directory: no permissions |
| `make release`   | Build Release, copy it to `.release/mvim.app`                        |
| `make dist`      | `release`, then notarize it and stage its update in `dist/`          |
| `make publish`   | `release`, then notarize it, stage its update and release it on GitHub |
| `make clean`     | Remove `build/`, `dist/` and the `.xcodeproj`                        |
| `make distclean` | `clean`, plus remove `.release/`                                     |

`make release` launches and installs nothing. `make clean` leaves `.release/` alone (see
[Start at login](#start-at-login)); `make distclean` removes it too. The Release build number is the
commit count, which is how [updates](#updates) are ordered. `make dist` and `make publish` need the
GitHub CLI, `gh`, and the certificate and credentials of
[Publishing an update](#publishing-an-update).

By hand:

```sh
xcodegen generate
xcodebuild -project mvim.xcodeproj -scheme mvim -configuration Debug \
  -derivedDataPath build build
```

## Project layout

```
mvim/
├── project.yml                 # XcodeGen spec — 2 framework targets + the app
├── Makefile                    # gen / build / run / test / release / dist / publish / clean / …
├── Info.plist                  # Sparkle's feed and key, merged into the generated plist
├── mvim.entitlements           # intentionally empty — mvim runs non-sandboxed
├── LICENSE                     # GPL-3.0
├── docs/
│   ├── reference.md            # this file
│   └── images/                 # the README's icon and demo
├── scripts/
│   └── sparkle-release.sh      # notarizes, stages and publishes updates (make dist / publish)
├── Sources/
│   ├── Core/                   # Core framework — what the engine stands on: InputHub
│   │                           #   (one shared CGEventTap), KeyEvent/Mods, field reads
│   │                           #   (AX, MarkerText, WebAreaWalk), Synth (posted keys), Prefs,
│   │                           #   capability config (Surface, CapabilityConfig,
│   │                           #   CapabilitySeeds), SecureInput, LoginItem, Log.
│   │                           #   NO Keychain in mvim's copy.
│   ├── Vim/                    # Vim framework (→ Core) — modal editing:
│   │   ├── Key,Model,Raw,      #   pure engine (no AppKit/AX; `make test` compiles this):
│   │   │   Logical,Physical,   #   the keystroke gate, vocabulary, parsing + key
│   │   │   State,Text,Sim,     #   assembly, planners, state + reducer, text math,
│   │   │   Learn,Field         #   simulated host, the learner's beliefs, the field's
│   │   │                       #   reads, snapshot and capabilities
│   │   └── Runtime/            #   tap routing, AX execution, Controller, Diag, PasteboardLoan,
│   │                           #   Beliefs (the beliefs file)
│   └── App/                    # mvim app — composition root: MvimApp (the menu-bar
│                               #   menu, the whole UI), its AppModel, and Updater (Sparkle)
├── Tests/
│   ├── VimEngineTests/         # `make test`: the engine driven through Sim, as preconditions
│   ├── PasteboardTests/        # `make test-pasteboard`: the paste's loan on a private pasteboard
│   └── BeliefsTests/           # `make test-beliefs`: the beliefs file in a temporary directory
└── Resources/
    ├── AppIcon.icon/           # App icon: an Icon Composer document, edited in Icon Composer
    └── Assets.xcassets         # Accent color (still empty)
```

## Modules

`mvim (app) → Vim → Core`, one-way and compiler-enforced; the app also imports Core directly. Vim's
pure engine (everything under `Sources/Vim` except `Runtime/`) has no AppKit/AX dependency and is
unit-tested standalone via `make test`, with the pure Core files the Makefile lists. Only the app
links [Sparkle](https://sparkle-project.org), pinned to an exact version in `project.yml`.

## Signing

`project.yml` signs the two configurations differently, both under the team it names:

- **Debug** (`make build`, `make run`) signs with a stable **Apple Development** identity
  (`CODE_SIGN_STYLE: Automatic`) so the Accessibility / Input Monitoring grants persist across
  rebuilds — an ad-hoc signature would change every build and macOS would revoke the grants each
  time.
- **Release** (`make release`, `make dist`, `make publish`) signs with the team's **Developer ID
  Application** certificate, which is what Apple's notary service takes: under the hardened runtime,
  with a secure timestamp, and without `get-task-allow`, the entitlement that lets other processes
  attach a debugger. That holds for the app, both frameworks and Sparkle's helpers. The style is
  `Manual` because Xcode's automatic signing cannot use Developer ID.

[`mvim.entitlements`](../mvim.entitlements) stays empty under the hardened runtime too: Accessibility and
Input Monitoring are grants, not entitlements. The two configurations share one bundle identifier and
differ in signature, so going from a Debug build to a Release one on the same Mac, or back, costs the
grants each time.

To build under a different team, change `DEVELOPMENT_TEAM` in `project.yml`: every `make build` and
`make release` regenerates the Xcode project from it, so a team picked in Xcode does not stick. Keep
that change out of pull requests.

Without those certificates, `SIGN` signs one `make build`, `make run` or `make release` another way,
leaving `project.yml` alone. `make run SIGN=-` signs ad-hoc: it builds anywhere, but macOS revokes
the grants at every build. `SIGN="<name>"` signs with another code-signing identity in the keychain,
such as your own Apple Development certificate or a self-signed one, named in full as
`security find-identity -v -p codesigning` prints it; switching to or from it costs the grants once,
and they persist across its builds. A `SIGN` build is not hardened: the hardened runtime loads an
app's frameworks only when they carry its team, and an ad-hoc or self-signed signature has none.
`make dist` and `make publish` refuse `SIGN`, since only `project.yml`'s Developer ID signature can be
notarized, and installs keep their grants only while updates keep it.

## Start at login

The menu's **Start at Login** toggle registers mvim with `SMAppService.mainApp`, the API that
replaced `SMLoginItemSetEnabled`. The system owns the bit — nothing is mirrored into `Prefs`.
Three consequences worth knowing:

- **It needs a real signature.** `SMAppService` fails with `kSMErrorInvalidSignature` on a bundle
  that is not properly code-signed, so the toggle needs a build made with an Apple Development
  or Developer ID identity — see [Signing](#signing).
- **Registration records the bundle's path.** Move the app afterwards and the item still points at
  the old location; `make clean` strands one registered from `build/`, and `make distclean` or
  deleting the clone one registered from `.release/`. Register from wherever mvim will actually
  live, such as `/Applications`.
- **A denial in System Settings is one-way from mvim's side.** Switching the item off under System
  Settings → General → Login Items leaves the status at `requiresApproval` — registered but denied —
  and `register()` cannot clear it. The menu shows the toggle unchecked and grows an **Approve mvim
  in Login Items Settings** row.

A login-launched mvim keeps its Accessibility and Input Monitoring grants: same bundle, same
signature.

## Updates

Every build embeds [Sparkle](https://sparkle-project.org), but a build has update items only when
its Info.plist names both a feed and a public key. `project.yml` gives both to Release builds
alone, so a Debug build never updates. Release builds update themselves from this repository's
GitHub releases: the feed is the `appcast.xml` attached to the latest one.

- **Sparkle asks first.** On mvim's second launch it asks whether to check once a day, and
  whether to install what it finds without asking. **Check for Updates Automatically** in the
  menu changes the first answer; the checkbox in the update window changes the second.
- **Check for Updates…** checks now. When a daily check finds an update later than right after
  launch, the item reads **Update to mvim X…** instead: a menu-bar app has no window to bring
  forward, so Sparkle would otherwise open its window behind your work.
- **Grants survive an update** because TCC holds them against the app's designated requirement,
  and `make publish` refuses a build that fails the current release's — see below.
- **An update is notarized like a download.** Sparkle removes the quarantine mark from what it
  installs, so Gatekeeper never checks an update; `make dist` and `make publish` check it instead,
  and stage nothing else.
- **Sparkle updates only a copy it can replace.** One run from Downloads or from a disk image it
  cannot, and by default it does not say so: keep mvim in `/Applications` ([Install](../README.md#install)).
- **What goes out:** a request to github.com for the feed, and the download when you install.
  Sparkle's anonymous system profiling stays off.

### Publishing an update

Once, on the Mac you will publish from:

1. Check at [developer.apple.com](https://developer.apple.com/account) → Membership that the Apple
   Developer Program membership of the team in `project.yml` is active. Without it there is no
   Developer ID certificate and no notarizing.
2. Create the team's **Developer ID Application** certificate: Xcode → Settings → Accounts →
   Manage Certificates… → **+**. Only the team's Account Holder can, and its private key stays in
   this Mac's keychain.
3. Store credentials for Apple's notary service in the keychain, under a profile name you choose:

   ```sh
   xcrun notarytool store-credentials mvim-notary --apple-id <your Apple ID> --team-id <your team ID>
   ```

   It asks for an app-specific password: [account.apple.com](https://account.apple.com) → Sign-In
   and Security → App-Specific Passwords makes one. `make dist` and `make publish` take the
   profile's name from `NOTARY_PROFILE`.
4. Get the Sparkle key into the login keychain. `SPARKLE_PUBLIC_KEY` in `project.yml` already holds
   its public half, so on another Mac import the private half: run `make release`, which resolves
   Sparkle, then `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f <backup>`. A
   fork makes a pair of its own with `generate_keys` alone and commits the public key it prints.
5. Back the private key up — `generate_keys -x <file>`, then store the file somewhere safe.
   Installed copies check every update against that key, and `make publish` releases under no other.
6. `gh auth login`: the release is created with the GitHub CLI.

For each release, from a clean checkout of `main` on that Mac:

1. Bump `MARKETING_VERSION` in `project.yml` and merge it.
2. `NOTARY_PROFILE=mvim-notary make dist` builds the app, sends it to the notary service and waits
   for the answer, which Apple says typically comes within an hour, staples the ticket to
   `.release/mvim.app`, and stages `dist/mvim-<version>.zip`, its notes (GitHub's, from the merged
   pull requests) and `appcast.xml` without publishing anything. Allow the keychain prompts the
   first time.
3. `NOTARY_PROFILE=mvim-notary make publish` does all of that again, then creates release
   `v<version>` holding the zip and the appcast. Installed copies find it at their next check.

Both notarize the app as a zip, staple the ticket to the app, which a zip cannot carry, and zip it
again, so Sparkle signs the archive that ships. `make dist` and `make publish` both stop when:

- `gh` is missing, `NOTARY_PROFILE` is not set, `SUPublicEDKey` is empty, or the feed is not a GitHub
  latest-release asset;
- the app is not signed with a Developer ID Application certificate, which a `SIGN` build and a
  Debug build are not;
- GitHub can write no release notes for `HEAD` because it is not pushed;
- the notary service does not answer that it accepted the app: a rejection prints the service's log,
  which names each file it objects to;
- the ticket cannot be stapled, or the app unpacked from the finished zip lacks its ticket or does
  not pass Gatekeeper as a notarized Developer ID app: the zip reaches `dist/` only after that;
- the appcast item came out unsigned because the key is not the one `SUPublicEDKey` names.

`make publish` also refuses to release when:

- the app does not satisfy the designated requirement of the latest release's app — TCC holds
  Accessibility and Input Monitoring against that requirement, so every install would lose both. A
  Developer ID requirement names the team, not the certificate, so any Developer ID Application
  certificate of the same team satisfies it; for a deliberate change, such as moving to another
  team, `SPARKLE_NEW_IDENTITY=1 make publish` publishes anyway;
- `SUPublicEDKey` is not the latest release's. Installs check an update against the key they shipped
  with, and Sparkle takes a new key only from an update that keeps the Developer ID signature, never
  both changed at once; the script holds the key fixed, with no override. On a new Mac, import the
  original key with `generate_keys -f <backup>`; never paste a freshly generated one into
  `project.yml`;
- the tree has uncommitted changes, `HEAD` is not on `main`, `v<version>` exists, or the build
  number does not exceed the one the latest release offers, which installs would ignore;
- GitHub cannot answer any of those questions: a failed read refuses rather than guesses.

The first release skips the checks against the latest release.

`SPARKLE_KEY_FILE=<file>` signs with a key file instead of the keychain.

The zip holds the app with its ticket stapled, so Gatekeeper needs no network to check a copy
downloaded in a browser, and macOS opens it after its one confirmation for an app from the Internet.

## Diagnostics

mvim records one line per **command decision** to `os_log`, under subsystem
`io.github.celve.mvim`. The unit is the decision, not the keystroke: what a reader wants back is
*"the engine believed X about this field, and X was false"*.

```sh
log show --predicate 'subsystem == "io.github.celve.mvim"' --last 1h --info --debug
log collect --last 2h --output mvim.logarchive     # the whole system log: share it privately
```

A command that did **not** fully succeed logs at `.default` and is persisted to disk for
free, surviving the quit a stranded user is about to perform. A clean command logs at
`.debug`, which is off until asked for:

```sh
sudo log config --subsystem io.github.celve.mvim --mode "level:debug,persist:debug"
sudo log config --subsystem io.github.celve.mvim --mode "level:default"    # off again — it is sticky
```

The renderers live on the engine types themselves, under a `// MARK: - Recorder` banner in
each type's file; `grep -rn '// MARK: - Recorder' Sources` is the index.

Six categories: `bind` (a field became vim's, with its whole capability resolution),
`cmd` (the anchor event), `settle` (a prediction the field did not meet, and what it
answered instead), `learn` (the evidence a command gave, a [belief](#learned-beliefs) that
changed, or the reason nothing was learned), `gate` (an
element that did not become a binding, and a web field's walk to its site) and `system` (the
tap or the login item failing). Every engine line carries `e<epoch>.c<seq>` — the binding
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
(`fail=lineStartKey`) when a caret key left a selection, when the field still reads as it did
before the key although the key had somewhere to go, or when the key landed somewhere else. In
Chromium's rich text a landing somewhere else aborts without learning. Where a key's lane exempts a
failure from blame, a `learn` line says so: `evidence q=lineStartKey neutral why=paragraph-lines
seen=settle@1` (a line key off target in Chromium's rich text), `why=empty-paragraph` (a key from a
caret in an empty paragraph mvim could not give a line) or `why=web-content` (a word or paragraph key that stayed put in web
content).

Before an edit deletes or types over a selection, it checks the selected text: `ciw` is
`W!!R!CCC` with AX selection writes and `P2P5!!P?CCC` without, where the second `!` waits for
`AXSelectedText` to equal the text the plan selected from `AXValue`, not counting the U+FFFC
Chromium writes into it for each icon or other element with no text. A misread caret puts keys
and exact writes alike on other text while every offset reads back as planned. A failed check
presses ← to drop that selection, leaves mvim in Normal mode, and tells the
[offsets belief](#learned-beliefs) that its answer does not fit. Its `settle` line adds `text=(N)`,
a length and never the text, on both sides (the text itself only with text recording on); a
`FAIL` whose `sel` and `len` agree failed on the text.

`abort@N` names the step that ended the run, and the `C`s behind it did **not** all die with
it: a commit carrying residency still lands (`VimEffect.survivesAbort`), which is why an
aborted line can read `ok=0` and `mode=normal→insert` together.

A Chromium rich-text field (a contenteditable in Chrome, Dia or an Electron app; its bind
line says `chromium=1 offsets=textContent/…`) names its selection in text content: `AXValue`
without the `\n` Chromium generates where a paragraph starts. mvim plans in `AXValue` offsets and
converts at the field's edge, so a `settle` line's `want` and `got` are the field's own offsets,
behind the planner's by the paragraph breaks before them. Where one field offset is both a
paragraph's end and the next one's start, `edge=end` or `edge=start` says which the settle waited
for. `AXValue` leaves out an empty paragraph that sits between two others; mvim finds those in the
accessibility tree and plans with each as a line of its own, while a settle's `len` stays
`AXValue`'s, and `empty=N` on a `cmd` line is how many lines the plan had that `AXValue` lacks.
The reverse holds for the text `AXValue` gives that no caret reaches, such as a list marker, a
to-do's checkbox or a mention chip past its first character: the plan leaves it out, so the field's
offsets run ahead of the plan's by what it left out before them, and `folded=N` is how many units of
`AXValue` it took.

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
defaults write io.github.celve.mvim mvimRecordText -bool YES
defaults delete io.github.celve.mvim mvimRecordText
```

**Both edges need a relaunch.** The flag is read once per process, deliberately — re-reading
it per line would put a `UserDefaults` lookup on the command path — so `defaults delete`
does not stop an mvim that is already running.

## Browsers and Electron apps

Chromium browsers and Electron apps, such as Chrome, Dia and Linear, let mvim read a field, and some,
such as Linear in Dia, let it set the selection too, so mvim moves and selects there by writing it.
Where a field takes no writes, or mvim has learned that they fail, mvim runs the same Normal-mode
commands by pressing keys (arrows, ⌃A and ⌃E, ⌘↑ and ⌘↓) with no block cursor, and checks the field
after each step: when the field does not answer as planned, it beeps and stops rather than edit the
wrong text. In these apps `o` and `O` paste their
new line, because ⏎ could send a message. Blank lines are lines there as in Vim, except in a document
of more than about 250 paragraphs, a list's markers, to-do boxes and a code block's language label are
not, and a mention chip is one character on its paragraph's line, so `j` and `k` count the lines Linear
shows, and columns start after a list item's `• ` or `1. `. In a field mvim cannot read at all, and
under **Force**, moves are
approximate, deletes and yanks go through ⌘X and ⌘C so the clipboard is the register, and
search, marks and Visual mode beep. **Notion** comes with its own defaults, since each of its blocks
is a separate field.

An input or a plain text area keeps mvim while a row of its popup list is highlighted, as in Linear's
⌘K menu or a search box's suggestions, though Chromium then calls that row, not the field, the focused
element. Pick the row from Insert mode: in Normal mode the arrow keys and ⏎ are Vim's motions. A
rich-text editor with anything in it still loses mvim while such a row is highlighted, because
nothing there tells mvim whether the editor has the focus. An empty one is a known limit: mvim cannot
tell it from an empty text area, so it keeps mvim, even if the page has moved the focus onto a row of
its list. mvim then stays in its mode, and in Normal mode it takes the keys meant for that row until
you press `i`.

mvim also learns. When one of the field's writes, or one of the app's keys mvim relies on, fails its
check (it lands wrong, or not within a quarter of a second) three commands in a row, mvim switches that
capability off for fields like the one it failed in until the app updates. A command where it works
starts the count over, and so does relaunching mvim; the app's own word and paragraph keys go off after
one failure. **Capabilities** then lists it first, under
**Learned for …** with the day it failed, and **Try Again** forgets it so mvim tries it afresh.
Some failures only stop the command: a key landing elsewhere in Chromium's rich text, a word key
doing nothing in web content, anything under **Force**, and any capability you set yourself. mvim
also learns how a field counts caret positions: where the field's reads stop agreeing with it, it
stops trusting the caret (**Read caret** shows under **Learned for …** as Off) and treats the field
as one it cannot read, and a capability switched off while mvim misread a field comes back once it
counts that field anew, reading **Trying again here** in the menu.
**On …** and **Off …** override what mvim detected or learned, for one field, fields like it, a site
or the whole app. Those choices and what mvim learned are kept in a file you can edit as well:
**Open Beliefs File** opens it (see [The beliefs file](#the-beliefs-file)). **App's word,
paragraph & page keys**, off by default, hands `w` `e` `b` `iw` `{` `}` `gj` `gk` ⌃F ⌃B to the
app's own keys: see [Native word, paragraph and page keys](#native-word-paragraph-and-page-keys).

## Native keys

When a field can be read but not written, mvim moves by line and document with the standard
Cocoa bindings instead of counting arrow presses: ⌃A/⌃E to the start and end of the caret's
paragraph, which is mvim's line, ⇧⌃A/⇧⌃E to select there, and ⌘↑/⌘↓ (⇧ to select) for the
document. `dd` is ⌃A, ⇧⌃E, ⇧→; `j` is ⌃E, → and then the column counted on the new line; `0`,
`$`, `gg`, `G`, `D`, `C`, `cc`, `yy`, `o`, `O`, `J` and linewise puts follow the same pattern.
`x` and `X` still select one character and check it before deleting, because ⌦ and ⌫ would
delete first and join lines at a line end. Where a field is written but a write cannot land a line's
start or end alone, as beside Linear's list markers and chips, mvim presses ⌃A or ⌃E instead, and a
selection it wrote reaches a line's end by ⇧⌃E where no chip is in the way.

Where mvim still counts arrows, it takes the way with fewer presses. `j` and `k` count the column from
the nearer end of the new line: `j` adds a ⌃E to start from its end, and `k`'s last ← already lands
there. A move within a line goes by ⌃A or ⌃E and arrows back when that is fewer keys than counting
from the caret, a selection from the caret by ⇧⌃A or ⇧⌃E and ⇧ arrows back, and a selection that ends
at the caret by ⇧← from it. Each of these is an optional route: counting from the caret reaches the same
place without it. So the first time a route's settle fails, mvim plans without that route in fields like
that one and counts again, until mvim is relaunched or the app updates. The failed settle names the
route in its `want` (`route=line-start`, `route=line-end` or `route=select-back`), and the key itself
is not blamed. Arrows, ⌃A and ⌃E are posted with no pause between key down and key up; every other key
keeps 2 ms.

In Linear, → or ↓ from the last line of a list, a code block or a quote stops once before another of
the three that follows it directly, and so does ↑ coming back; next to a paragraph or a heading there is
no stop. mvim marks the first line after each stop, so `j`, `w`, a counted `$` and the like press through
it: ⇧→ →, or → → into a to-do, which ⇧→ will not extend into. Two quotes side by side show nothing in
the text, so in a ProseMirror editor mvim reads the document's blocks whenever the text has more than one
line, and again when a block changes kind, and marks a stop only between blocks that carry Linear's own
classes: any other editor's quote or list gets no stop it did not get before. A table or a collapsible
section has the stop too and is not marked, nor is one between blocks inside a quote.

Each key is a row in the Capabilities menu — **Line start key (⌃A)**, **Line end key (⌃E)**,
**Document start key (⌘↑)**, **Document end key (⌘↓)** — claimed for every field whose text
and caret mvim can read. A key that lands anywhere but where it
should, including a caret key that leaves a selection (as a select-all binding would) or a key that does
nothing where it had somewhere to go, is learned off for that surface after three such misses in a row,
like a write that lies, and mvim counts arrows there again; **Try Again** in the menu lets it try the key afresh. In Chromium's rich
text a key that lands somewhere else only aborts the command, because one paragraph can be several
`AXValue` lines there (a mention chip) and a working key lands off the model's line; its `learn` line
says `why=paragraph-lines`, and you can turn such a key off from the menu.

Chromium's rich text (Dia, Chrome, Electron apps such as Linear) reports the caret without the
paragraph breaks before it; mvim reads it through text markers and puts the breaks back,
and where that fails the caret is unknown and the command goes blind. Which fields count this
way is a [belief](#learned-beliefs), checked on every snapshot. Keys are pressed
even where a command has nothing to select or `j`/`k` stays on its line, so a settle still checks
the caret the command starts from. An empty paragraph can be missing from `AXValue`, with a caret
in it reading as the end of the line above, so mvim looks for these in the accessibility tree once
per text and gives each a line. Where it cannot, in a field of more than about 250 blocks
or when a read fails, a key pressed from a caret whose marker sits on an empty paragraph is not
blamed for seeming to do nothing. In such a field a yank within one line takes its register from
the text the field selected. A list item's marker (`•`, `1.`) is a line of its own in Linear's
`AXValue`, and so is each icon, checkbox or heading menu that is a block, and the language label above
a code block's code; no caret stands on any of them, so mvim leaves them out of its lines. The label of
a code block inside a list item or a quote stays a line, and `j` or `k` across it beeps. A page's own
list (`<li>`) starts each item's line with
its marker and a space, which no caret stands in either, so mvim leaves those out too. A mention
chip is a line of its own in Linear's `AXValue` too, though it sits inside its paragraph, and the
caret crosses it in one step: mvim gives it its paragraph's line back and counts it as one
character, whose register text is the chip's label. mvim tells markers
and chips from text in the accessibility tree, once per text; where it cannot, in a field of more
than about a hundred list items and chips or when a read fails, they stay lines and `j` or `k` into
one beeps. Edits across list items run without checking the length, since a list renumbers and
items gain or lose their markers, and nothing types over a chip, since typed text cannot rebuild
one. A chip that ends its paragraph is followed by a `<br>` the caret reads as already past, and
beside a chip Linear gives the caret an `AXValue` line of its own for as long as it stays there, so
in a document with chips the settles do not check the length. Where mvim can set the selection, it
never sets the caret at a chip's start, after which the next arrow does nothing; it sets it at the
chip's end and presses ←.

A register pasted where the field takes no AX insertion borrows the pasteboard. mvim saves every
item in every type it holds, puts the text up for one ⌘V (marked `org.nspasteboard.TransientType`,
so clipboard histories that honour it skip it), and puts the rest back once a settle sees the caret
land after the paste. Nothing else says when the app has read it, so a paste no caret confirms
stays up for a second: one where mvim cannot read the field, or one carrying a newline in Chromium
rich text, whose settles check the length alone, as `o` and `O` below do. Your own ⌘V,
and a paste of `+`, `*` or a blind cut's register, gets your contents back first; if the app has
not read mvim's paste by then, that paste gets your contents too. A copy or cut made meanwhile is
newer and is kept.

`o` and `O` paste their newline in web content: typed, it makes no paragraph in Chromium's rich
text, and ⏎ would send a chat message. Chromium leaves the new empty paragraph out of `AXValue`
until it holds text, so the settles after it do not check the length. In a field where mvim found
empty paragraphs, an edit that empties a line or types into an empty one changes which of them
`AXValue` shows, so the settles after it check neither the length nor the paragraph side.

## Learned beliefs

mvim learns three kinds of answer about each kind of field — every field of one role on one site,
or in one app natively — and keeps them in the [beliefs file](#the-beliefs-file):

- **Writes** (`writeSelection`, `insertText`) and **native keys**: the probe claims them, and three
  settle failures in a row blamed on one set it off for that kind of field until the app updates. A
  pass in between starts the count over, as do a new offsets answer and a new app version, and the
  count lasts only while mvim runs. The app's word and paragraph keys (`wordKeys`, `paragraphKeys`)
  still go off after one.
- **Offsets**: how the field counts caret and selection offsets. `value` is `AXValue`'s count,
  `textContent` is Chromium's without the paragraph breaks it generates (the text-marker path),
  and `untrusted` withholds the caret, so commands take the blind lane (`ciw` is ⌥← ⇧⌥→ ⌘X
  there, and Visual mode rings). A Chromium field with children starts at `textContent` and any
  other field at `value`; a field with no children (a `<textarea>`, an `<input>`) has no generated
  breaks, so it always counts as `AXValue` does and teaches nothing. Every snapshot compares the
  plain `AXSelectedTextRange` with the text markers, and a selection's `AXSelectedText` with what
  each answer predicts. One observation moves the answer toward `textContent` or `untrusted`, on
  the snapshot it was made on; evidence for `value` moves it back only when the web engine changed
  (an Electron app's framework, else the app), and otherwise to `untrusted`. Under `value` the
  markers are read only where they could tell something, a newline at or before the plain caret,
  and a binding stops after three such reads say nothing.

A write or key answer records the offsets answer it was judged under and holds only while that
answer does: a demotion made while mvim misread the field's offsets reopens once the offsets answer
changes. Demotions from before beliefs carry over as judged under `value`.

Each piece of evidence is one `learn` line, `evidence q=<question> <outcome> why=<reason> seen=<where>`:
the outcome is `supports`, `refutes` or `neutral`, and `seen` is `snapshot` or `settle@N`, the plan
step. A failed settle's line is logged; passes and snapshot reads only at debug level. A struck
write says why: `unanswered`, `length`, `moved` (the selection read back elsewhere) or `edge` (the
offsets held but not the paragraph side). A struck key says `unmoved`, `left-selection`, `too-long` or
`off-target`, and the `commit` line that sets it off repeats the reason; a failure short of the third
logs `strike <n>/3 q=<question> why=<reason> rung=<rung>` instead.

The bind line shows the read model as `offsets=<answer>/<source>`, where the source is `start`
(the rule above), `learned`, `user` or `plain` (no children), followed by one `belief` line per
stored answer that touched the field, with its provenance and whether it is `in-force`, `reopened`,
`stale` (another engine's), `not-this-field` (a field with no children) or only `dates-engine`. In
the menu, **Capabilities** opens on what a belief switched off in the field, a demotion or **Read
caret** while it is `untrusted`, with the day and until when it holds, and on verdicts reopened in
this field, which read **Trying again here** and are not counted in the badge. **Try Again**, or
**Forget** for a reopened verdict, removes those beliefs and makes no choice. A learned `value` or
`textContent` only shows under **Read caret**: forgetting it would restart the field at an answer
its reads already moved it off. Choosing On or Off for a row retires what fields like this one
learned about it.

## The beliefs file

`~/Library/Application Support/mvim/beliefs.json` keeps the choices made with **On …** and **Off …**
and the [learned beliefs](#learned-beliefs). It is JSON for you to read and edit, and **Open Beliefs
File** in the menu opens it:

```json
{
  "beliefs" : [
    {
      "answer" : "broken",
      "appVersion" : "153.0.6943.98",
      "judgedUnder" : "textContent",
      "provenance" : {
        "build" : "1.0.0 (812)",
        "learnedAt" : "2026-09-28T07:00:00Z",
        "tag" : "e3.c7"
      },
      "question" : "insertText",
      "rung" : "com.google.Chrome|linear.app|role:AXTextArea"
    }
  ],
  "overrides" : {
    "com.tinyspeck.slackmacgap" : {
      "nativeMotions" : "on"
    }
  },
  "schema" : 3
}
```

- `overrides` maps a rung, then a capability, to `on` or `off`, as the menu's On and Off write them.
  A rung is `<bundle ID>` for an app, `<bundle ID>|<site>` for a site in it, `…|role:<role>` for
  fields like one (natively `<bundle ID>|role:<role>`) and `…|id:<identifier>` for one field; the
  bind line's `rung=` prints a field's role rung.
- The capabilities, by menu row: `readText`, `readLength`, `readCaret`, `readSelectedText` (the
  Read rows), `writeSelection` (Set selection), `insertText` (Replace text), `drawCursor`,
  `wholeDocument`, `fieldIsSession` (New field starts a session), `lineStartKey`, `lineEndKey`,
  `documentStartKey`, `documentEndKey`, `nativeMotions` (App's word, paragraph & page keys),
  `wordKeys` and `paragraphKeys`.
- Each of `beliefs` is one learned answer. `question` is a write (`writeSelection`, `insertText`), a
  key (`lineStartKey`, `lineEndKey`, `documentStartKey`, `documentEndKey`, `wordKeys`,
  `paragraphKeys`) or `offsets`, and `answer` is `broken` for a write or key, or `value`,
  `textContent` or `untrusted` for `offsets`. A write or key answer holds only at `appVersion`, and
  only while the field's offsets answer is `judgedUnder` (`value` when absent). An offsets answer
  holds only at `engineVersion`, an Electron app's framework version, else at `appVersion`, and not
  while `anchor` is true. `provenance` (mvim's build, when, and by which command) and `tally` (the
  evidence counted) are for reading; an entry needs `provenance`, even as `{}`.

mvim rereads the file whenever it binds a field, so an edit applies when you next focus one. An
override you write lasts, as one chosen in the menu does, and beats a belief. A belief you write is
treated as learned: evidence can move an offsets answer, and an app update reopens a verdict. mvim
writes the file for the menu and for what it learns, but only over the version it read: an edit you
save in between is read back, and the change is made to it instead.

A file mvim cannot use is never written over: bad JSON, a missing key, another `schema`, an answer
its question cannot take, or an override other than `on` or `off`. mvim goes on applying the last
version that read, across relaunches too: the menu shows its choices, and the **Open Beliefs File**
row reads **Open Beliefs File — unreadable, last good version in use**. Each bind logs a
`beliefs-file` line in `learn` with the
reason, and neither lessons nor menu choices are saved until the file reads again. A question or
capability name mvim does not know is kept and ignored. Builds before the file kept overrides and
beliefs in the `capabilityOverrides` and `fieldBeliefs` defaults, which move to the file on first
launch and are dropped once a file reads. To forget one lesson, choose **Try Again** in its row, or
**Forget** for one on trial; to forget everything mvim learned, empty `beliefs`. Deleting the file
drops your choices as well:

```sh
rm ~/Library/Application\ Support/mvim/beliefs.json
```

## Native word, paragraph and page keys

Off by default. **Capabilities in _App_ › App's word, paragraph & page keys** turns it on for one
field, fields like it, a site or the whole app. With it on, mvim presses the app's own keys
instead of counting arrows or ringing, and the app decides where they land:

| Vim | Keys |
|---|---|
| `w` `e` / `b` | ⌥→ / ⌥← |
| `iw` (`ciw` `diw` `yiw` `viw`) | ⌥→ ⌥← to the word's start, then ⌥→ ⇧⌥← over it, then ⌘X or ⌘C |
| `dw` `de` `cw` `ce` `yw` / `db` `cb` `yb` | ⇧⌥→ / ⇧⌥←, then ⌘X or ⌘C. From a word's edge, and in scripts written without spaces (Chinese, Japanese, Thai, Lao, Myanmar, Khmer), ⌥→ and ⌥← go out and back first |
| `{` `}` | ⌥↑ / ⌥↓ |
| `gj` `gk` | ↓ / ↑ |
| `j` `k` | ↓ / ↑, only where ⌃E/⌃A are demoted and mvim cannot land them on a line |
| `^F` `^B` | ⌥PgDn / ⌥PgUp. Without the option, ⌃F and ⌃B stay the app's |

- **Where it applies.** Words switch only in fields mvim can read but not select in, such as
  Chromium and Electron editors, and `iw` also in fields it cannot read. A field that sets its
  selection exactly keeps vim's words; the paragraph, row and page keys work in every field.
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
  it is demoted on that surface: **Word keys (⌥← ⌥→)** or **Paragraph keys (⌥↑ ⌥↓)** then shows
  under **Learned for …**. In web content, where reads cannot tell a key that did nothing, only a
  move that leaves a selection behind is demoted. Words go back to counting and paragraphs to
  ringing until you choose Try Again or override it, or the app updates.

## Synthesized events

mvim tags every event it posts with `SynthTag.magic` (`0x4345_4C56`, in `Sources/Core/Synth.swift`),
and its tap passes tagged events through before any handler runs. **The magic is a cross-app ABI:**
Vibe, the author's dictation app, tags its typing with the same value, so Normal mode never runs a
transcript as commands. Never change the magic in one app without the other.
