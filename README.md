# Norm

System-wide **Vim mode** for macOS — a native SwiftUI **menu bar** app. Norm layers modal
editing (Normal / Insert / Visual, operators, motions, registers, `/` search) over every
text field on the system.

Norm is one half of the former **Loom** app — the other half is **Sotto**, the
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

This generates `Norm.xcodeproj` from `project.yml` and builds the app. The binary lands at:

```
build/Build/Products/Debug/Norm.app
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
.release/Norm.app
```

Nothing is launched or installed — open it yourself. `make clean` leaves `.release/`
alone (see [Start at login](#start-at-login)); `make distclean` removes it too.

### Other targets

| Command          | Description                                    |
| ---------------- | ---------------------------------------------- |
| `make gen`       | Generate `Norm.xcodeproj` from `project.yml`   |
| `make build`     | Generate + build a Debug binary                |
| `make run`       | Build, then launch the Debug `Norm.app`        |
| `make test`      | Run the pure Vim engine tests                  |
| `make release`   | Build Release, copy it to `.release/Norm.app`  |
| `make clean`     | Remove `build/` and the generated `.xcodeproj` |
| `make distclean` | `clean`, plus remove `.release/`               |

### Manual invocation

```sh
xcodegen generate
xcodebuild -project Norm.xcodeproj -scheme Norm -configuration Debug \
  -derivedDataPath build build
```

## Project layout

```
norm/
├── project.yml                 # XcodeGen spec — 2 framework targets + the app
├── Makefile                    # gen / build / run / release / clean / distclean / test
├── Norm.entitlements           # intentionally empty — Norm runs non-sandboxed
├── Sources/
│   ├── Core/                   # LoomCore framework — shared, feature-agnostic:
│   │                           #   InputHub (one shared CGEventTap), KeyEvent/Mods/Trigger,
│   │                           #   AX/Clipboard/Synth, Prefs store, LoginItem (start at
│   │                           #   login). NO Keychain in Norm's copy.
│   ├── Vim/                    # LoomVim framework (→ Core) — modal editing:
│   │   ├── Key,Model,Raw,      #   pure engine (no AppKit/AX; `make test` compiles this):
│   │   │   Logical,Physical,   #   the keystroke gate, vocabulary, parsing + key
│   │   │   State,Text,Sim,     #   assembly, planners, state + reducer, text math,
│   │   │   Trace               #   simulated host, the recorder's renderers
│   │   └── Runtime/            #   tap routing, AX execution, Controller, Diag
│   └── App/                    # Norm app — composition root: NormApp, NormSettingsView,
│                               #   LegacyMigration (one-time Loom settings import)
└── Resources/
    └── Assets.xcassets         # App icon + accent color (placeholders)
```

### Modules

`Norm (app) → LoomVim → LoomCore`, one-way and compiler-enforced. The framework names keep
their Loom heritage — they are internal targets, invisible at runtime. Vim's pure engine
(everything under `Sources/Vim` except `Runtime/`) has no AppKit/AX dependency and is
unit-tested standalone via `make test`.

The generated `Norm.xcodeproj` is intentionally git-ignored — it is a build artifact. Edit
`project.yml` to change build settings, then regenerate.

## Permissions, trust, first launch

Norm needs **Accessibility** (read/drive text fields via AX, post synthesized events) and
**Input Monitoring** (its consuming `CGEventTap`). That is the whole list — by construction
Norm contains **no microphone, network, or keychain code**, and its Info.plist carries no
microphone usage string. After granting a permission for the first time, relaunch the app —
an already-created event tap cannot retro-enable itself.

On first launch Norm imports the vim slice of your old combined-Loom settings (per-app
profiles, toggles) from the `com.loom.Loom` defaults domain — once, guarded by the
`migratedFromLoomV1` sentinel; nothing is written back. If you previously granted the
combined Loom app permissions, its rows in System Settings → Privacy & Security are now
orphans — remove them manually.

## Start at login

The menu's **Start at Login** toggle registers Norm with `SMAppService.mainApp`, the
API that replaced `SMLoginItemSetEnabled`. The system owns the bit — nothing is
mirrored into `Prefs`, and the menu re-reads the real status every time it opens.
Three consequences worth knowing:

- **It needs a real signature.** `SMAppService` requires a properly code-signed
  bundle and fails with `kSMErrorInvalidSignature` otherwise, so the toggle needs a
  build made with the Apple Development identity — see [Signing](#signing).
- **Registration records the bundle's path.** Register from
  `build/Build/Products/Debug/Norm.app` and a `make clean` strands the login item;
  move the app afterwards and it still points at the old location. `.release/Norm.app`
  is the stable path `make clean` spares — but it still lives inside the repo, so
  `make distclean` or deleting the clone strands the item just the same. Register
  from wherever Norm will actually live.
- **A denial in System Settings is one-way from Norm's side.** Switching the item off
  under System Settings → General → Login Items leaves the status at
  `requiresApproval` — registered but denied — and `register()` cannot clear it. The
  menu shows the toggle unchecked and grows an **Approve Norm in Login Items
  Settings** row.

A login-launched Norm keeps its Accessibility and Input Monitoring grants: same
bundle, same signature.

## Diagnostics

Norm records one line per **command decision** to `os_log`, under subsystem
`com.loom.Norm`. The unit is the decision, not the keystroke: what a reader wants back is
*"the engine believed X about this field, and X was false"*.

```sh
log show --predicate 'subsystem == "com.loom.Norm"' --last 1h --info --debug
log collect --last 2h --output norm.logarchive     # to send somewhere
```

A command that did **not** fully succeed logs at `.default` and is persisted to disk for
free, surviving the quit a stranded user is about to perform. A clean command logs at
`.debug`, which is off until asked for:

```sh
sudo log config --subsystem com.loom.Norm --mode "level:debug,persist:debug"
sudo log config --subsystem com.loom.Norm --mode "level:default"    # off again — it is sticky
```

Five categories: `bind` (a field became vim's, with its whole capability resolution),
`cmd` (the anchor event), `settle` (a prediction the field did not meet, and what it
answered instead), `learn` (a demotion committed, or the reason one was not), `gate` (an
element that did not become a binding). Every line carries `e<epoch>.c<seq>` — the binding
and the command — so `grep -E 'e12\b'` is the whole join. A bind line is `e12 …` and a
command line `e12.c47 …`; the word boundary catches both and keeps `e120` out.

Reading a `cmd` line, `steps=` is the ordered, payload-free plan; `Trace`'s doc comment has
the alphabet. Order is the diagnostic — a `!` (hard settle) directly after a `P` (blind
keypress) is a settle that can never name the capability it failed, so it rings without
teaching the learner anything.

**Text is not recorded.** No renderer can emit a text payload, and that is a unit test
rather than a convention. Search patterns and Ex command lines are reduced to their length;
everything else in `keys=` is vim syntax. The opt-in, which the menu does not offer and
every `bind` line announces while it is on:

```sh
defaults write com.loom.Norm normRecordText -bool YES
defaults delete com.loom.Norm normRecordText
```

**Both edges need a relaunch.** The flag is read once per process, deliberately — re-reading
it per line would put a `UserDefaults` lookup on the command path — so `defaults delete`
does not stop a Norm that is already running.

## Running alongside Sotto

- **`SynthTag.magic` is a cross-app ABI.** Both apps tag their synthesized CGEvents with the
  same magic (`0x4C4F_4F4D`, in each repo's `Sources/Core/Synth.swift`) and bypass tagged
  events before any handler runs. Norm's consuming tap must bypass Sotto's synthesized
  typing — otherwise vim Normal mode would consume a transcript as commands. **Never change
  the magic in one app without the other.**
- **Bare-modifier-tap triggers in Sotto can false-fire around vim.** Both apps install
  head-insert event taps; their relative order depends on launch order. When Norm consumes a
  key-down (Normal mode), Sotto's tap never observes it — e.g. vim consuming `⌃[` makes the
  surrounding `⌃` press look like a clean bare tap. Prefer Sotto's default `⌃⌥D` combo (a
  Carbon hotkey — no tap at all), an `Fn`/🌐 tap, or a double-tap. This is a documented
  limitation; the apps deliberately share no IPC.
- Clipboard transactions are serialized per-process only. A simultaneous Norm register paste
  and Sotto insertion fallback could interleave in principle; humanly this does not occur.

## Signing

The project signs with a stable **Apple Development** identity (`CODE_SIGN_STYLE: Automatic`,
team in `project.yml`) so the Accessibility / Input Monitoring grants persist across
rebuilds — an ad-hoc signature would change every build and macOS would revoke the grants
each time. To build under a different team, change `DEVELOPMENT_TEAM` in `project.yml`.
