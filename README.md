# mvim

Vim's modal editing in the text fields of your Mac. mvim lives in the menu bar: it reads and edits the
focused field through Accessibility, and takes the keys it needs with a keyboard event tap.

A field starts in Insert mode, unless you reach it from another block of the same document.
**⌃[ enters Normal mode**, and Esc does too if you choose it in the menu.

There is no release yet, so [build it from source](#install). mvim needs macOS 14 or later, and it is
free software under the [GNU GPL](#license).

## Install

You need Xcode 16 or later (the full app, not only its command-line tools),
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), and an **Apple
Development** signing certificate, which Xcode → Settings → Accounts → Manage Certificates… creates.

1. Clone this repository and set `DEVELOPMENT_TEAM` in [`project.yml`](project.yml) to your team ID,
   the `OU=` value this prints. macOS keeps mvim's permissions only while its signature stays the
   same, and an ad-hoc signature changes with every build ([Signing](#signing)).

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

2. Build it and copy it to where it will live, since [Start at Login](#start-at-login) remembers the
   path:

   ```sh
   make release
   rm -rf /Applications/mvim.app && ditto .release/mvim.app /Applications/mvim.app
   open /Applications/mvim.app
   ```

3. Allow **Input Monitoring** when macOS asks. mvim does not ask for **Accessibility**: choose **Open
   Accessibility Settings** in its menu and switch mvim on there.
4. Quit mvim and open it again, since it creates its keyboard tap only at launch. The menu should now
   read `Input tap: running`, `Accessibility: granted` and `Input Monitoring: granted`.

To update, quit mvim, run `git pull --autostash && make release` and copy the app again; the
permissions carry over while the same Apple Development identity signs it. To uninstall, switch
**Start at Login** off, quit and delete the app, remove it from Accessibility and Input Monitoring in
System Settings → Privacy & Security, and run `defaults delete com.loom.mvim`.

## Using it

**⌃[** enters Normal mode, leaves Visual mode and cancels a half-typed command. It is Control and the
key to the right of P, whatever the keyboard layout. By default **Esc stays the app's**, for its own
cancels and dialogs. Choose **Esc** under **Normal Mode Key** in the menu and Esc does what ⌃[ does,
except in Normal mode with nothing half-typed, where it still goes to the app: press Esc twice to
close a dialog, a popup or Spotlight from a field. ⌃[ keeps working either way. The menu-bar icon
shows the mode: a keyboard while mvim is not in a field, otherwise **i**, **n** or **v** in a square.
Where mvim can set the selection, Normal mode also draws a block cursor. Nothing shows a half-typed
command, or a `/` search as you type it. Moving between the blocks of one document, as in Notion,
keeps the mode you were in.

In Insert mode mvim takes only ⌃[, and Esc if you chose it. In Normal and Visual mode apps still keep
every ⌘ and ⌥ combination, Esc unless you chose it, Home, End, Page Up and Page Down, the function
keys, and every ⌃ combination but ⌃[, ⌃R and ⌃V, and ⌃F and ⌃B while
[the app's own page keys](#native-word-paragraph-and-page-keys) are on. So ⌃A, ⌃E and ⌃K work as in
any Mac text field, and a key mvim does not know beeps instead of typing.

The menu is mvim's whole interface. **Vim Mode** turns mvim off everywhere until you turn it back on
or mvim starts again. **Normal Mode Key** chooses ⌃[ or Esc for every app. **Vim in _App_** chooses,
per app:

- **Auto**: mvim works in text fields, text areas and combo boxes, but never in password fields.
- **Off**: mvim leaves the app alone. Terminals and code editors start Off: Terminal, iTerm2, kitty,
  Alacritty, WezTerm, Ghostty, Warp, Visual Studio Code, Cursor, Xcode, Zed, VimR, Neovide and the
  JetBrains IDEs.
- **Force**: for apps that expose no text field to Accessibility. mvim drives the front window
  without reading it, with arrow keys and ⌘Z, ⌘X, ⌘C and ⌘V, and a click returns to Insert mode.

**Capabilities in _App_** shows what mvim can do in the current field and lets you override it (see
[Browsers and Electron apps](#browsers-and-electron-apps)). The rest of the menu reports the tap and
both permissions, opens their System Settings panes, and holds [Start at Login](#start-at-login).
mvim also stands aside while macOS has Secure Event Input on, as it does in a password field.

## What works

A subset of Vim. In a field mvim can read and write, as in most native Mac apps:

| | |
|---|---|
| **Move** | `h` `j` `k` `l` and the arrow keys, `w` `W` `e` `E` `b` `B`, `0` `^` `$` `g_`, `gg` `G`, `+` `-` ⏎, `f` `F` `t` `T` `;` `,` |
| **Search** | `/` or `?`, the text, ⏎; then `n` `N`. Literal text, case-sensitive, wrapping around the end |
| **Marks** | `m` and a letter; then `'` or `` ` `` and the letter to jump back, in the same field, until its text is edited |
| **Operators** | `d` `c` `y` `g~` `gu` `gU` with a motion, `iw` `aw` `iW` `aW`, or doubled (`dd` `cc` `yy` `g~~` `guu` `gUU`), but not yet with `gg`, `g_` or a search as the motion |
| **Edit** | `x` `X` `s` `S` `r` `C` `D` `Y` `J` `gJ` `~` `p` `P` `.`, and `u` and ⌃R, which press the app's own ⌘Z and ⇧⌘Z |
| **Insert** | `i` `a` `I` `A` `o` `O` `gi` |
| **Visual** | `v`, motions or `iw` `aw`, then `d` `c` `y` `~` `u` `U` `>` `<`. A selection can end one character short of Vim's, and `V` and ⌃V select characters, not lines or blocks |
| **Counts** | Most commands take one. `gg` `G` `C` `D`, the Insert commands, `u` and ⌃R ignore it |
| **Registers** | `"a`–`"z` (`"A`–`"Z` append), `"0`–`"9`, `"-`, `"_`, `".`, `"/`, kept until mvim quits. `"+p` and `"*p` paste the Mac clipboard, but a yank does not copy to it |

These beep instead: `:` and `q`, after which the keys you type run as Normal-mode commands; `@`; `z`
commands; the operators `=` `!` `gq` `gw`; text objects other than words (`ip` `i(` `i"` `it` …); the
motions `ge` `%` `(` `)` `H` `M` `L` `*` `#` `[[` `]]`; and `g-` `g+` `&` `gR` `Q`. So do `{` `}` `gj`
`gk`, unless [the app's own keys](#native-word-paragraph-and-page-keys) are on.

## Browsers and Electron apps

Chromium browsers and Electron apps, such as Chrome, Dia and Linear, let mvim read a field but not set
its selection. There mvim runs the same Normal-mode commands by pressing keys (arrows, ⌃A and ⌃E, ⌘↑
and ⌘↓), and checks the field after each step: when the field does not answer as planned, it beeps and
stops rather than edit the wrong text. There is no block cursor there, and `o` and `O` paste their
new line, because ⏎ could send a message. In a field mvim cannot read at all, and under **Force**,
moves are approximate, deletes and yanks go through ⌘X and ⌘C so the clipboard is the register, and
search, marks and Visual mode beep. **Notion** comes with its own defaults, since each of its blocks
is a separate field.

mvim also learns. When one of the field's writes, or one of the app's keys mvim relies on, fails its
check (it lands wrong, or not within a quarter of a second), mvim switches that capability off for
fields like the one it failed in, and **Capabilities** marks it `✗ learned` until the app updates.
Some failures only stop the command: a key landing elsewhere in Chromium's rich text, a word key
doing nothing in web content, anything under **Force**, and any capability you set yourself. mvim
also learns how a field counts caret positions: where the field's reads stop agreeing with it, it
stops trusting the caret (**Read caret** `✗ learned`) and treats the field as one it cannot read,
and a capability switched off while mvim misread a field comes back once it counts that field anew.
**On …** and **Off …** override what mvim detected or learned, for one field, fields like it, a site
or the whole app, and `defaults delete com.loom.mvim fieldBeliefs` forgets everything learned (see
[Learned beliefs](#learned-beliefs)). **App's word, paragraph & page keys**, off by default, hands
`w` `e` `b` `iw` `{` `}` `gj` `gk` ⌃F ⌃B to the app's own keys: see
[Native word, paragraph and page keys](#native-word-paragraph-and-page-keys).

## Privacy

mvim needs **Accessibility**, to read and edit the focused field and to post keys, and **Input
Monitoring**, for its keyboard tap. The tap sees every key you press, but mvim acts only on keys typed
into a field it is working in. mvim has no microphone, keychain or networking code, and
[Sparkle](#updates) is built in but inactive until the first release. Its settings and its log name
the apps and websites you use. The log also records the Normal-mode commands you type, but never the
text you insert or a command's operand, count or register (a unit test holds it to that), unless you
turn on [text recording](#diagnostics); if mvim ever mistook the mode, some of your words could reach
it as commands. mvim pastes through the clipboard into fields it cannot write, and restores the
clipboard afterwards; in fields it cannot read, cut and copy use the clipboard itself.

## Reporting a bug

Open an [issue](https://github.com/celve/mvim/issues) with your macOS version, the output of
`git rev-parse --short HEAD`, the app (and the site, in a browser), the keys you typed, what happened
and what you expected, and a screenshot of the **Capabilities** menu. A command that fails is always
logged, so attach the last hour of mvim's log, after reading it, since it names apps and sites:

```sh
log show --predicate 'subsystem == "com.loom.mvim"' --last 1h --info --debug > mvim.log
```

Never post a `log collect` archive: it holds your whole system log. To log the commands that succeed
as well, see [Diagnostics](#diagnostics).

## Development

The Xcode project is generated from [`project.yml`](project.yml) by XcodeGen and built with
`xcodebuild`. `mvim.xcodeproj` is git-ignored: edit `project.yml`, then regenerate.

| Command          | Description                                                          |
| ---------------- | -------------------------------------------------------------------- |
| `make gen`       | Generate `mvim.xcodeproj` from `project.yml`                         |
| `make build`     | Generate, then build Debug to `build/Build/Products/Debug/mvim.app`  |
| `make run`       | Build, then launch the Debug `mvim.app`                              |
| `make test`      | Run the pure engine's tests: no Xcode project, no permissions        |
| `make release`   | Build Release, copy it to `.release/mvim.app`                        |
| `make dist`      | `release`, then stage its update in `dist/`                          |
| `make publish`   | `release`, then stage its update and release it on GitHub            |
| `make clean`     | Remove `build/`, `dist/` and the `.xcodeproj`                        |
| `make distclean` | `clean`, plus remove `.release/`                                     |

`make release` launches and installs nothing. `make clean` leaves `.release/` alone (see
[Start at login](#start-at-login)); `make distclean` removes it too. The Release build number is the
commit count, which is how [updates](#updates) are ordered. `make dist` and `make publish` need the
GitHub CLI, `gh`.

By hand:

```sh
xcodegen generate
xcodebuild -project mvim.xcodeproj -scheme mvim -configuration Debug \
  -derivedDataPath build build
```

### Project layout

```
mvim/
├── project.yml                 # XcodeGen spec — 2 framework targets + the app
├── Makefile                    # gen / build / run / test / release / dist / publish / clean / …
├── Info.plist                  # Sparkle's feed and key, merged into the generated plist
├── mvim.entitlements           # intentionally empty — mvim runs non-sandboxed
├── LICENSE                     # GPL-3.0
├── scripts/
│   └── sparkle-release.sh      # stages and publishes an update (make dist / publish)
├── Sources/
│   ├── Core/                   # LoomCore framework — what the engine stands on: InputHub
│   │                           #   (one shared CGEventTap), KeyEvent/Mods, field reads
│   │                           #   (AX, MarkerText, WebAreaWalk), Synth (posted keys), Prefs,
│   │                           #   capability config (Surface, CapabilityConfig,
│   │                           #   CapabilitySeeds), SecureInput, LoginItem, Log.
│   │                           #   NO Keychain in mvim's copy.
│   ├── Vim/                    # LoomVim framework (→ Core) — modal editing:
│   │   ├── Key,Model,Raw,      #   pure engine (no AppKit/AX; `make test` compiles this):
│   │   │   Logical,Physical,   #   the keystroke gate, vocabulary, parsing + key
│   │   │   State,Text,Sim,     #   assembly, planners, state + reducer, text math,
│   │   │   Learn               #   simulated host, the learner's beliefs
│   │   └── Runtime/            #   tap routing, AX execution, Controller, Diag
│   └── App/                    # mvim app — composition root: MvimApp (the menu-bar
│                               #   menu, the whole UI), its AppModel, and Updater (Sparkle)
├── Tests/
│   └── VimEngineTests/         # `make test`: the engine driven through Sim, as preconditions
└── Resources/
    └── Assets.xcassets         # App icon + accent color (both still empty)
```

### Modules

`mvim (app) → LoomVim → LoomCore`, one-way and compiler-enforced; the app also imports LoomCore
directly. The framework names keep their Loom heritage — they are internal targets, invisible at
runtime — and so does the `com.loom` prefix, which names the bundle ID, the defaults domain and the
log subsystem. Vim's pure engine (everything under `Sources/Vim` except `Runtime/`) has no AppKit/AX
dependency and is unit-tested standalone via `make test`, with the pure Core files the Makefile
lists. Only the app links [Sparkle](https://sparkle-project.org), pinned to an exact version in
`project.yml`.

### Signing

The project signs with a stable **Apple Development** identity (`CODE_SIGN_STYLE: Automatic`,
team in `project.yml`) so the Accessibility / Input Monitoring grants persist across
rebuilds — an ad-hoc signature would change every build and macOS would revoke the grants
each time. To build under a different team, change `DEVELOPMENT_TEAM` in `project.yml`: every
`make build` and `make release` regenerates the Xcode project from it, so a team picked in Xcode
does not stick. Keep that change out of pull requests.

### Start at login

The menu's **Start at Login** toggle registers mvim with `SMAppService.mainApp`, the API that
replaced `SMLoginItemSetEnabled`. The system owns the bit — nothing is mirrored into `Prefs`.
Three consequences worth knowing:

- **It needs a real signature.** `SMAppService` fails with `kSMErrorInvalidSignature` on a bundle
  that is not properly code-signed, so the toggle needs a build made with an Apple Development
  identity — see [Signing](#signing).
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

### Updates

Every build embeds [Sparkle](https://sparkle-project.org), but a build has update items only when
its Info.plist names both a feed and a public key. `project.yml` gives both to Release builds
alone, and `SPARKLE_PUBLIC_KEY` stays empty until the first release, so no build updates yet. Once
it is set, Release builds update themselves from this repository's GitHub releases: the feed is the
`appcast.xml` attached to the latest one.

- **Sparkle asks first.** On mvim's second launch it asks whether to check once a day, and
  whether to install what it finds without asking. **Check for Updates Automatically** in the
  menu changes the first answer; the checkbox in the update window changes the second.
- **Check for Updates…** checks now. When a daily check finds an update later than right after
  launch, the item reads **Update to mvim X…** instead: a menu-bar app has no window to bring
  forward, so Sparkle would otherwise open its window behind your work.
- **Grants survive an update** because TCC holds them against the app's designated requirement,
  and `make publish` refuses a build that fails the current release's — see below.
- **What goes out:** a request to github.com for the feed, and the download when you install.
  Sparkle's anonymous system profiling stays off.

#### Publishing an update

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

`make dist` and `make publish` both stop when `gh` is missing, `SUPublicEDKey` is empty, the feed
is not a GitHub latest-release asset, the app is ad-hoc signed — every install would lose its
grants on updating — GitHub can write no release notes for `HEAD` because it is not pushed, or the
appcast item came out unsigned because the key is not the one `SUPublicEDKey` names.

`make publish` also refuses to release when:

- the app does not satisfy the designated requirement of the latest release's app — TCC holds
  Accessibility and Input Monitoring against that requirement, so every install would lose both. An Apple Development requirement names the certificate's holder, so
  publish from the same person's certificate; for a deliberate change, such as moving to
  Developer ID, `SPARKLE_NEW_IDENTITY=1 make publish` publishes anyway;
- `SUPublicEDKey` is not the latest release's: installs verify with the key they shipped with, so
  every install would reject the update. On a new Mac, import the original key with
  `generate_keys -f <backup>`; never paste a freshly generated one into `project.yml`;
- the tree has uncommitted changes, `HEAD` is not on `main`, `v<version>` exists, or the build
  number does not exceed the one the latest release offers, which installs would ignore;
- GitHub cannot answer any of those questions: a failed read refuses rather than guesses.

The first release skips the checks against the latest release.

`SPARKLE_KEY_FILE=<file>` signs with a key file instead of the keychain.

Releases are not notarized: they carry the Apple Development signature, so a copy downloaded from
GitHub in a browser opens only after **Open Anyway** in System Settings → Privacy & Security.
Updates Sparkle installs are not quarantined. Notarizing takes a `Developer ID Application`
certificate, the hardened runtime and `notarytool`.

### Diagnostics

mvim records one line per **command decision** to `os_log`, under subsystem
`com.loom.mvim`. The unit is the decision, not the keystroke: what a reader wants back is
*"the engine believed X about this field, and X was false"*.

```sh
log show --predicate 'subsystem == "com.loom.mvim"' --last 1h --info --debug
log collect --last 2h --output mvim.logarchive     # the whole system log: share it privately
```

A command that did **not** fully succeed logs at `.default` and is persisted to disk for
free, surviving the quit a stranded user is about to perform. A clean command logs at
`.debug`, which is off until asked for:

```sh
sudo log config --subsystem com.loom.mvim --mode "level:debug,persist:debug"
sudo log config --subsystem com.loom.mvim --mode "level:default"    # off again — it is sticky
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
caret in an empty paragraph) or `why=web-content` (a word or paragraph key that stayed put in web
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
for.

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

### Native keys

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
mention chip) and a working key lands off the model's line; its `learn` line says
`why=paragraph-lines`, and you can turn such a key off from the menu.

Chromium's rich text (Dia, Chrome, Electron apps such as Linear) reports the caret without the
paragraph breaks before it; mvim reads it through text markers and puts the breaks back,
and where that fails the caret is unknown and the command goes blind. Which fields count this
way is a [belief](#learned-beliefs), checked on every snapshot. Keys are pressed
even where a command has nothing to select or `j`/`k` stays on its line, so a settle still checks
the caret the command starts from. An empty paragraph can be missing from `AXValue`, and a caret
in one reads as its neighbour's, so a key pressed from a caret whose marker sits on an empty
paragraph is not blamed for seeming to do nothing. In such a field a yank within one line takes its register from
the text the field selected.

`o` and `O` paste their newline in web content: typed, it makes no paragraph in Chromium's rich
text, and ⏎ would send a chat message. Chromium leaves the new empty paragraph out of `AXValue`
until it holds text, so the settles after it do not check the length.

### Learned beliefs

mvim learns three kinds of answer about each kind of field — every field of one role on one site,
or in one app natively — and keeps them in `fieldBeliefs`, a disposable cache:

- **Writes** (`writeSelection`, `insertText`) and **native keys**: the probe claims them, and one
  settle failure blamed on one sets it off for that kind of field until the app updates. A pass
  changes nothing.
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
`off-target`, and the `commit` line that sets it off repeats the reason.

The bind line shows the read model as `offsets=<answer>/<source>`, where the source is `start`
(the rule above), `learned`, `user` or `plain` (no children), followed by one `belief` line per
stored answer that touched the field, with its provenance and whether it is `in-force`, `reopened`,
`stale` (another engine's), `not-this-field` (a field with no children) or only `dates-engine`. In
the menu, a demotion reads `✗ learned`, and so does **Read caret** while the field is `untrusted`;
choosing On or Off for a row retires the belief behind it. To flush them all:

```sh
defaults delete com.loom.mvim fieldBeliefs
```

### Native word, paragraph and page keys

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
  it is demoted on that surface: **Word keys (⌥← ⌥→)** or **Paragraph keys (⌥↑ ⌥↓)** then reads
  `✗ learned`. In web content, where reads cannot tell a key that did nothing, only a move that
  leaves a selection behind is demoted. Words go back to counting and paragraphs to ringing until
  you override it or the app updates.

### Synthesized events

mvim tags every event it posts with `SynthTag.magic` (`0x4C4F_4F4D`, in `Sources/Core/Synth.swift`),
and its tap passes tagged events through before any handler runs. **The magic is a cross-app ABI:**
Vibe, the author's dictation app, tags its typing with the same value, so Normal mode never runs a
transcript as commands. Never change the magic in one app without the other.

## License

Copyright © 2026 Linyu Wu

mvim is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE) for
the full terms.

Builds embed [Sparkle](https://sparkle-project.org), which carries its own MIT license.
