# mvim

System-wide **Vim mode** for macOS — a native SwiftUI **menu bar** app. mvim layers modal
editing (Normal / Insert / Visual, operators, motions, registers, `/` search) over every
text field on the system.

mvim is one half of the former **Loom** app — the other half is **Sotto**, the
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
alone (see [Start at login](#start-at-login)); `make distclean` removes it too.

### Other targets

| Command          | Description                                    |
| ---------------- | ---------------------------------------------- |
| `make gen`       | Generate `mvim.xcodeproj` from `project.yml`   |
| `make build`     | Generate + build a Debug binary                |
| `make run`       | Build, then launch the Debug `mvim.app`        |
| `make test`      | Run the pure Vim engine tests                  |
| `make release`   | Build Release, copy it to `.release/mvim.app`  |
| `make clean`     | Remove `build/` and the generated `.xcodeproj` |
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
├── Makefile                    # gen / build / run / release / clean / distclean / test
├── mvim.entitlements           # intentionally empty — mvim runs non-sandboxed
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
│                               #   menu, the whole UI) and its AppModel
└── Resources/
    └── Assets.xcassets         # App icon + accent color (placeholders)
```

### Modules

`mvim (app) → LoomVim → LoomCore`, one-way and compiler-enforced. The framework names keep
their Loom heritage — they are internal targets, invisible at runtime. Vim's pure engine
(everything under `Sources/Vim` except `Runtime/`) has no AppKit/AX dependency and is
unit-tested standalone via `make test`.

The generated `mvim.xcodeproj` is intentionally git-ignored — it is a build artifact. Edit
`project.yml` to change build settings, then regenerate.

## Permissions, trust, first launch

mvim needs **Accessibility** (read/drive text fields via AX, post synthesized events) and
**Input Monitoring** (its consuming `CGEventTap`). That is the whole list — by construction
mvim contains **no microphone, network, or keychain code**, and its Info.plist carries no
microphone usage string. After granting a permission for the first time, relaunch the app —
an already-created event tap cannot retro-enable itself.

### Upgrading from Norm

This app was called **Norm**. The rename moved the bundle identifier from `com.loom.Norm` to
`com.loom.mvim`, and macOS keys the privacy grants, the preferences domain and the login item
on it, so nothing carries across by itself — there is no migration code:

1. **In Norm's menu, switch Start at Login off, then quit Norm.** Two copies would each
   install a consuming event tap and fight over every keystroke. Then delete the old `Norm.app` —
   `.release/Norm.app` survives `make clean`. An item left behind can be removed under System
   Settings → General → Login Items.
2. **Grant mvim Accessibility and Input Monitoring**, then relaunch it. Norm's rows in System
   Settings → Privacy & Security (and the combined Loom app's, if still there) are orphans —
   remove them manually.
3. **Settings** — per-app Auto / Off / Force, capability overrides, learned priors — stay in the
   `com.loom.Norm` domain, which is left in place. Carry them across while mvim is not running,
   or re-enter them from the menu:

   ```sh
   defaults export com.loom.Norm - | defaults import com.loom.mvim -
   ```

   The import merges: a key both domains hold takes Norm's value, and every other key is kept.

Diagnostics move with the identifier: logs from before the rename stay under subsystem
`com.loom.Norm`, and the text-recording flag is now `mvimRecordText`.

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

Order is the diagnostic — a `!` directly after a `P` is a hard settle verifying a blind
keypress, which can never name the capability it failed, so it rings without teaching the
learner anything.

`abort@N` names the step that ended the run, and the `C`s behind it did **not** all die with
it: a commit carrying residency still lands (`VimEffect.survivesAbort`), which is why an
aborted line can read `ok=0` and `mode=normal→insert` together. Before that, the mode change
sat behind the settle and a lying field decided which mode Norm was in — `mode=normal→normal`
on a `steps=W!R!CCC abort@3` line is the signature of that bug.

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

## Running alongside Sotto

- **`SynthTag.magic` is a cross-app ABI.** Both apps tag their synthesized CGEvents with the
  same magic (`0x4C4F_4F4D`, in each repo's `Sources/Core/Synth.swift`) and bypass tagged
  events before any handler runs. mvim's consuming tap must bypass Sotto's synthesized
  typing — otherwise vim Normal mode would consume a transcript as commands. **Never change
  the magic in one app without the other.**
- **Bare-modifier-tap triggers in Sotto can false-fire around vim.** Both apps install
  head-insert event taps; their relative order depends on launch order. When mvim consumes a
  key-down (Normal mode), Sotto's tap never observes it — e.g. vim consuming `⌃[` makes the
  surrounding `⌃` press look like a clean bare tap. Prefer Sotto's default `⌃⌥D` combo (a
  Carbon hotkey — no tap at all), an `Fn`/🌐 tap, or a double-tap. This is a documented
  limitation; the apps deliberately share no IPC.
- Clipboard transactions are serialized per-process only. A simultaneous mvim register paste
  and Sotto insertion fallback could interleave in principle; humanly this does not occur.

## Signing

The project signs with a stable **Apple Development** identity (`CODE_SIGN_STYLE: Automatic`,
team in `project.yml`) so the Accessibility / Input Monitoring grants persist across
rebuilds — an ad-hoc signature would change every build and macOS would revoke the grants
each time. To build under a different team, change `DEVELOPMENT_TEAM` in `project.yml`.
