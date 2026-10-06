<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="mvim's icon: an m on a dark tile">
</p>

<h1 align="center">mvim</h1>

<p align="center">
  <b>Vim's modal editing in the text fields of your Mac.</b><br>
  A menu-bar app for macOS 14 or later. Free software under the GNU GPL.
</p>

<p align="center">
  <a href="https://github.com/celve/mvim/releases/latest"><b>Download</b></a> ·
  <a href="https://mvimsite.vercel.app">Home page</a> ·
  <a href="#what-works">What works</a> ·
  <a href="docs/reference.md">Reference</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/demo-dark.gif">
    <img src="docs/images/demo-light.gif" width="760" alt="Fix every typo: Esc enters Normal mode; /teh ⏎ finds the typo; ciw fixes it; n finds the next one, and . fixes it too; leaving “Check the draft and the slides before Friday.”">
  </picture>
</p>

<p align="center">
  <sub><b>Fix every typo.</b> Each step is what mvim's engine does with these keys, in its simulation of a
  native Mac text field, with Esc chosen as the Normal-mode key.
  The home page has <a href="https://mvimsite.vercel.app">more demos</a>.</sub>
</p>

mvim reads and edits the focused field through Accessibility, and takes the keys it needs with a keyboard
event tap. Type as usual, and press **⌃[** for Normal mode, or **Esc** if you choose it in the menu.

- **Vim's grammar, not only `hjkl`.** Operators with motions and word objects, counts, registers, marks,
  search, Visual mode and `.` ([What works](#what-works)).
- **Native apps, browsers and Electron apps.** Where a field takes no writes, mvim presses keys instead and
  checks the field after each step: it beeps and stops rather than edit the wrong text, and it
  [learns](#browsers-and-electron-apps) what each kind of field supports.
- **Your shortcuts stay yours.** A field starts in Insert mode, apps keep every ⌘ and ⌥ combination, and
  terminals and code editors start Off.
- **Private.** No networking code of its own: a release's only traffic is the update check, which asks first
  ([Privacy](#privacy)).

## Install

1. Download the [latest release](https://github.com/celve/mvim/releases/latest), unzip it, and move `mvim.app`
   to `/Applications` before you open it for the first time: Sparkle, which updates mvim, cannot update a copy
   run from Downloads or from a disk image, and by default it does not say so.
2. Open mvim and allow **Input Monitoring** when macOS asks. mvim does not ask for **Accessibility**: choose
   **Accessibility: not granted** in its menu and switch mvim on there.
3. Quit mvim and open it again, since it creates its keyboard tap only at launch. The menu should now read
   `Input tap: running`, `Accessibility: granted` and `Input Monitoring: granted`.
4. To enter Normal mode with Esc, choose **Esc** under **Normal Mode Key** in the menu.

A release is signed with a Developer ID certificate and notarized by Apple. It [updates](docs/reference.md#updates)
itself: on its second launch mvim asks whether to check once a day. You can also
[build mvim from source](docs/reference.md#building-from-source).

To uninstall, switch **Start at Login** off, quit and delete the app, remove it from Accessibility and Input
Monitoring in System Settings → Privacy & Security, run `defaults delete io.github.celve.mvim`, and delete
`~/Library/Application Support/mvim`.

## Using it

A field starts in Insert mode. Moving between the blocks of one document, as in Notion, keeps the mode you
were in.

**⌃[** enters Normal mode, leaves Visual mode and cancels a half-typed command. It is Control and the key to
the right of P, whatever the keyboard layout.

**Esc stays the app's** by default, for its own cancels and dialogs. Choose **Esc** under **Normal Mode Key**
and Esc does what ⌃[ does, except in Normal mode with nothing half-typed, where it still goes to the app:
press Esc twice to close a dialog, a popup or Spotlight from a field. ⌃[ keeps working either way.

The menu-bar icon shows the mode as a letter in a square:

| Icon | Meaning |
|---|---|
| Outlined **i** or **r** | Insert or Replace mode: keys type |
| Filled **n** or **v** | Normal or Visual mode: keys are commands |
| Dashed square | mvim is not working in a field |
| Slashed square | **Vim Mode** is off |
| **!** | Accessibility is not granted, or the input tap is not running |

Where mvim can set the selection, Normal mode also draws a block cursor. Nothing shows a half-typed command,
or a `/` search as you type it.

In Insert mode mvim takes only ⌃[, and Esc if you chose it. In Normal and Visual mode apps still keep every ⌘
and ⌥ combination, Esc unless you chose it, Home, End, Page Up and Page Down, the function keys, and every ⌃
combination but ⌃[, ⌃R and ⌃V, and ⌃F and ⌃B while
[the app's own page keys](docs/reference.md#native-word-paragraph-and-page-keys) are on. So ⌃A, ⌃E and ⌃K work
as in any Mac text field, and a key mvim does not know beeps instead of typing.

The menu is mvim's whole interface:

- **Vim Mode** turns mvim off everywhere until you turn it back on or mvim starts again.
- **Normal Mode Key** chooses ⌃[ or Esc for every app.
- **Vim in _App_** chooses, per app:
  - **Auto**: mvim works in text fields, text areas and combo boxes, but never in password fields.
  - **Off**: mvim leaves the app alone. Terminals and code editors start Off: Terminal, iTerm2, kitty,
    Alacritty, WezTerm, Ghostty, Warp, Visual Studio Code, Cursor, Xcode, Zed, VimR, Neovide and the
    JetBrains IDEs.
  - **Force**: for apps that expose no text field to Accessibility. mvim drives the front window without
    reading it, with arrow keys and ⌘Z, ⌘X, ⌘C and ⌘V, and a click returns to Insert mode.
- **Capabilities in _App_** shows what mvim can do in the current field, starting with what it learned to
  switch off in fields like it, and lets you override it; a badge on it counts what is off here.
- The status rows report the input tap and both permissions; the permission rows open their System Settings
  panes.
- [**Start at Login**](docs/reference.md#start-at-login) and, below it, **Open Beliefs File**, which opens the
  file that keeps your choices and what mvim has learned.

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
`gk`, unless [the app's own keys](docs/reference.md#native-word-paragraph-and-page-keys) are on.

## Browsers and Electron apps

Chromium browsers and Electron apps, such as Chrome, Dia and Linear, let mvim read a field, and some, such as
Linear in Dia, let it set the selection too, so mvim moves and selects there by writing it. Where a field
takes no writes, or mvim has learned that they fail, mvim runs the same Normal-mode commands by pressing keys
(arrows, ⌃A and ⌃E, ⌘↑ and ⌘↓) with no block cursor, and checks the field after each step: when the field
does not answer as planned, it beeps and stops rather than edit the wrong text.

**mvim learns.** When one of the field's writes, or one of the app's keys mvim relies on, fails its check
three commands in a row, mvim switches that capability off for fields like the one it failed in until the app
updates. **Capabilities** then lists it first, under **Learned for …** with the day it failed, and **Try
Again** forgets it so mvim tries it afresh. **On …** and **Off …** override what mvim detected or learned,
for one field, fields like it, a site or the whole app, and [a file you can edit](docs/reference.md#the-beliefs-file)
keeps those choices and what mvim learned.

What else differs there:

- `o` and `O` paste their new line, because ⏎ could send a message.
- `j` and `k` count the lines Linear shows: a list's markers, to-do boxes and a code block's language label
  are not lines, and a mention chip is one character on its paragraph's line.
- In a field mvim cannot read at all, and under **Force**, moves are approximate, deletes and yanks go
  through ⌘X and ⌘C so the clipboard is the register, and search, marks and Visual mode beep.
- **Notion** comes with its own defaults, since each of its blocks is a separate field.
- While a row of a field's popup list is highlighted, as in Linear's ⌘K menu, pick the row from Insert mode:
  in Normal mode the arrow keys and ⏎ are Vim's motions. A rich-text editor loses mvim meanwhile, except an
  empty one, which is a known limit: there Normal mode takes the keys meant for that row until you press `i`.
- **App's word, paragraph & page keys**, off by default, hands `w` `e` `b` `iw` `{` `}` `gj` `gk` ⌃F ⌃B to
  [the app's own keys](docs/reference.md#native-word-paragraph-and-page-keys).

The reference has [the full account](docs/reference.md#browsers-and-electron-apps), with what stops a command
without being learned, and [how mvim presses keys there](docs/reference.md#native-keys).

## Privacy

mvim needs **Accessibility**, to read and edit the focused field and to post keys, and **Input Monitoring**,
for its keyboard tap. The tap sees every key you press, but mvim acts only on keys typed into a field it is
working in.

- **Network.** mvim has no microphone, keychain or networking code of its own; a release build's only traffic
  is [Sparkle](docs/reference.md#updates)'s update check, which asks first.
- **Names.** Its settings, its beliefs file and its log name the apps and websites you use.
- **Commands, not text.** The log also records the Normal-mode commands you type, but never the text you
  insert or a command's operand, count or register (a unit test holds it to that), unless you turn on
  [text recording](docs/reference.md#diagnostics); if mvim ever mistook the mode, some of your words could
  reach it as commands.
- **Clipboard.** mvim pastes through the clipboard into fields it cannot write, and restores the clipboard
  afterwards; in fields it cannot read, cut and copy use the clipboard itself.

## Reporting a bug

Open an [issue](https://github.com/celve/mvim/issues) with your macOS version, mvim's version from Finder's
Get Info (or the output of `git rev-parse --short HEAD` for a build from source), the app (and the site, in a
browser), the keys you typed, what happened and what you expected, and a screenshot of the **Capabilities**
menu. A command that
fails is always logged, so attach the last hour of mvim's log, after reading it, since it names apps and
sites:

```sh
log show --predicate 'subsystem == "io.github.celve.mvim"' --last 1h --info --debug > mvim.log
```

Never post a `log collect` archive: it holds your whole system log. To log the commands that succeed as well,
see [Diagnostics](docs/reference.md#diagnostics).

## Development

mvim builds with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen), and `make test` runs the
engine's tests with no Xcode project and no permissions. The [reference](docs/reference.md) covers
[building from source](docs/reference.md#building-from-source), [signing](docs/reference.md#signing),
[publishing an update](docs/reference.md#publishing-an-update), [the log](docs/reference.md#diagnostics) and
[what mvim learns](docs/reference.md#learned-beliefs).

## License

Copyright © 2026 Linyu Wu

mvim is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. It is distributed WITHOUT ANY WARRANTY; see [LICENSE](LICENSE) for
the full terms.

Builds embed [Sparkle](https://sparkle-project.org), which carries its own MIT license.
