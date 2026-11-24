# SwiftRight

[简体中文](README.zh-CN.md)

<p align="center">
  <img src="docs/icon.png" width="112" alt="SwiftRight icon">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-blue" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

> Vibe-coded with DeepSeek V4.1 Flash 1017 / OpenCode.

A Finder context-menu extension for macOS. Define any shell command in a GUI and it shows up when you right-click, acting on whatever is selected. It can also generate terminal, editor and new-file commands for you.

Built with Swift / SwiftUI / Xcode. No third-party dependencies.

## Using the Finder extension

1. Open `SwiftRight.app` once — it writes the initial config and registers the extension with the system
2. **System Settings › General › Login Items & Extensions › Finder extensions** — enable **SwiftRight**
3. Right-click a file, or empty space in a Finder window
   - Commands with no group appear directly in the menu
   - Each group is a submenu; groups marked *Put in Submenu* are collected under a shared `SwiftRight ▸`
4. Click an item to run it. Execution can be silent in the background, stream into the output window, or hand off to any terminal
5. Manage commands from the menu bar icon → **Manage Commands…** (or double-click SwiftRight in Applications)
   - The sidebar is grouped; drag a command into another group to reassign it
   - Click a group title for its settings: enabled, title, icon, and whether it uses the submenu
   - Toolbar **⋯ → Sort…** opens a dedicated sort window with cross-group dragging and bulk toggles

![The command manager](docs/en/main.png)

The app does **not** need to stay running: the Finder extension reads the config on its own and the host app is launched on demand. To leave no background process at all, choose *Quit when idle* under **Settings › General › Background**.

## Features

- **Commands** — title, icon, group and script in a GUI; insert placeholders with one click, or write a `#!` script with environment variables
- **Groups** — grouped sidebar and sort window, drag to regroup or reorder; every group can be enabled separately, get its own icon, and opt into the shared submenu
- **Run modes** — silent background / output window (live stdout+stderr) / any terminal
- **Scope** — files only / folders only / both, plus an extension filter; non-matching commands never appear
- **Working directory** — folder containing the selection / the selected folder / current Finder window / custom (placeholders allowed)
- **Run options** — once per selected item, confirm before running, notify on finish, timeout (15s / 30s / 45s / 1 min presets plus a stepper)
- **Test Run** — pick files in the editor, run once and see the output without switching to Finder
- **Generators** — scan installed terminals and editors to create *Open … here* commands; built-in file templates power **New File**
- **Import / export** — commands and menu settings as JSON for backup or moving between Macs
- **Chinese / English** — switch instantly in settings

## Screenshots

| Settings | Sort window |
| --- | --- |
| ![Settings](docs/en/settings.png) | ![Sort window](docs/en/sort.png) |

---

## Install

### From a release build

Download `SwiftRight-<version>.dmg` (or `.zip`) from [Releases](https://github.com/whynbnb/SwiftRight/releases), drag **SwiftRight.app** into **Applications**, then:

```bash
xattr -dr com.apple.quarantine /Applications/SwiftRight.app
```

**That command is not optional.** The builds are ad-hoc signed and not notarized — see [Gatekeeper](#gatekeeper) below for why, and for what happens if you skip it.

Then follow [Using the Finder extension](#using-the-finder-extension) to open the app once and enable the extension.

### From source

Requires **macOS 15+**, **Xcode 16+** (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
swift Scripts/make-icon.swift   # optional: generate the app icon
./Scripts/build.sh              # generate project → build → install to /Applications → register
```

Locally built copies are signed with your own certificate and never quarantined, so no `xattr` step is needed.

Build without installing: `./Scripts/build.sh build`
Package a distributable: `./Scripts/package.sh` → `dist/` (zip + dmg, ad-hoc signed)
Develop in Xcode: `open SwiftRight.xcodeproj` (the project file is committed; `xcodegen` is only needed to regenerate it)

---

## Gatekeeper

Release builds are **ad-hoc signed and not notarized**, so macOS quarantines them on download and refuses to open them:

> "SwiftRight" is damaged and can't be opened.

That message is misleading — nothing is damaged. It is what Gatekeeper says about any app that carries a quarantine flag and no Developer ID signature. Removing the flag is enough:

```bash
xattr -dr com.apple.quarantine /Applications/SwiftRight.app
```

Skipping it also breaks the Finder extension silently: a quarantined bundle never gets registered, so no context menu appears and there is nothing to enable in System Settings.

Files transferred by AirDrop, USB or a local share are not quarantined, so those copies open straight away.

**Why not just notarize it?** Notarization requires a paid Apple Developer Program membership ($99/year) for a Developer ID certificate. Until then, ad-hoc signing is the honest alternative — and it has one advantage over signing with a development certificate: ad-hoc signatures carry no certificate, so they never expire. A development certificate lasts a year, and Xcode only requests a secure timestamp for Developer ID signatures, so a development-signed binary stops validating once the certificate lapses.

---

## Architecture

```
Finder ──right-click──▶ FinderExtension.appex  (sandboxed)
                        │  reads commands.json, builds the menu
                        │  on click: writes a ticket, opens swiftright://run?ticket=…
                        ▼
                 SwiftRight.app                (not sandboxed)
                        │  looks up the ticket → expands placeholders → Process
                        ▼
                 background / output window / terminal
```

**Why two processes?**

App extensions are sandboxed by the system, and inside that sandbox `Process` cannot launch anything external — which is the entire point of this tool. So the extension only builds menus; execution lives in the non-sandboxed host app.

The two sides communicate through `~/Library/Application Support/SwiftRight/`:

| File | Purpose |
|---|---|
| `commands.json` | Command definitions. Written by the app, read by the extension (mtime-cached, so edits apply on the next right-click — no need to restart Finder) |
| `pending/<uuid>.json` | One-shot invocation ticket. Written by the extension, consumed and deleted by the app |
| `scratch/` | Temporary `.command` scripts for terminal mode |

The extension reaches that one directory via a `temporary-exception.files.home-relative-path.read-write` entitlement, scoped to SwiftRight's own folder. **No App Group is used**, so no paid developer account is required.

Paths travel through a file rather than the URL: a multi-selection of long paths overflows a URL quickly, and percent-encoding path characters is error-prone.

Matching logic in `Shared/` compiles into both targets, so what the menu shows and what can actually run never diverge.

---

## Placeholders

Placeholders are **shell-quoted by default**, so paths with spaces, quotes or `$` are safe. Append `:raw` for the unescaped text (e.g. `{paths:raw}`).

| Placeholder | Meaning |
|---|---|
| `{path}` | Full path of the first selected item |
| `{paths}` | All selected items, space-separated |
| `{name}` | File name, with extension |
| `{names}` | All file names |
| `{basename}` | File name, without extension |
| `{ext}` | Extension, without the dot |
| `{dir}` | Containing folder |
| `{target}` | The folder of the current Finder window |
| `{count}` | Number of selected items |
| `{home}` | Home directory |
| `{date}` | Timestamp, `yyyyMMdd-HHmmss` |

Selected paths are **also** passed as positional arguments, so these are equivalent:

```bash
zip -r out.zip {paths}
zip -r out.zip "$@"
```

Environment variables are set too: `SR_PATH` `SR_PATHS` (newline-separated) `SR_DIR` `SR_TARGET` `SR_NAME` `SR_BASENAME` `SR_EXT` `SR_COUNT` `SR_HOME`.

A script starting with `#!` is written to a temporary executable and run via its shebang, ignoring the configured interpreter — so you can write Python, Ruby or AppleScript directly.

GUI processes inherit a narrow `PATH`, so `/opt/homebrew/bin` and `/usr/local/bin` are appended before running. Homebrew-installed tools just work.

---

## Command options

- **Execution** — silent background / live output window (streaming stdout+stderr) / hand off to a terminal
- **Working directory** — folder containing the selection / the selected folder itself / current Finder window / custom (placeholders allowed)
- **Scope** — files only / folders only / both, plus an extension filter. Commands that don't match simply don't appear in the menu
- **Groups** — commands sharing a group name collapse into a submenu; each group decides for itself whether it is enabled and whether it goes into the shared submenu
- **Run once per item** — spawn a process per selected file instead of passing them all at once (disabled when multiple selection is off)
- **Confirm before running** / **notify when finished** / **timeout** (15s / 30s / 45s / 1 min presets, stepper for fine tuning)

**Test Run** in the editor opens a file picker to stand in for the selection, runs once and shows the output — no switching to Finder to iterate.

Failed background commands open the output window by default; otherwise silent failures are hard to diagnose (switchable in settings).

---

## Generators

The toolbar `+` menu and the settings window can generate commands for you.

**Terminals.** Scans for installed terminals and generates *Open kitty here* style commands. Every terminal disagrees on command-line conventions, so launch recipes are built in and verified against each one's `--help`:

| Terminal | Arguments |
|---|---|
| Terminal / iTerm2 | `open -a <App> <script>` |
| kitty | `--directory {dir} {shell} {script}` |
| WezTerm | `start --cwd {dir} -- {shell} {script}` |
| Ghostty | `--working-directory={dir} -e {shell} {script}` |
| Rio | `--working-dir {dir} -e {shell} {script}` |
| Alacritty | `--working-directory {dir} -e {shell} {script}` |

Scanning only covers `/Applications`, `/System/Applications` and `~/Applications`. Copies registered from a dev or download folder are ignored, so unpacked installers don't show up; terminals installed elsewhere can be added with **Add Manually…**, and manual entries survive rescans.

Discovery beyond the built-in list filters on `CFBundleTypeRole == "Shell"` — apps declaring they *execute* shell scripts. Asking LaunchServices "who can open a shell script" instead pulls in Chrome, Notes, Pages and every text editor.

kitty, WezTerm, Ghostty and Rio close the window as soon as the command exits, so short commands flash past. **Keep the terminal open** (on by default) appends an interactive shell and prints the exit code.

**Editors.** Scans for installed editors and generates *Open Zed here* style commands. Unlike terminals these need no per-app recipe — `open -b <bundle id> <path>` works everywhere, and opening by bundle id survives the app being updated or moved. The scan scope matches terminals, and manual additions are kept.

The one thing recorded per editor is whether it can open a folder as a project, which decides whether the command applies to folders. This cannot be read from `Info.plist`: VS Code, Zed and VSCodium declare `public.folder`, but the JetBrains IDEs and Qt Creator do not — yet all of them support it.

**File templates.** Right-click a folder → **New File ▸** with a template, like Windows Explorer's *New*. Ships with Plain Text, Markdown, JSON, HTML, CSS, JavaScript, YAML, XML, Shell Script and Python; the last two get the executable bit. Name, default file name, extension, icon and initial contents are all editable, and you can add your own.

The generated command is an ordinary script using a heredoc, so it stays readable and editable. Name collisions increment the way Finder does (`Untitled 2.md`). Afterwards the new file is revealed and selected in Finder — press Return to rename.

---

## Settings

Open from the menu bar icon, or ⌘,

- **General** — language (System / 简体中文 / English, applied instantly), theme (System / Light / Dark), how the app stays in the background, whether a failed background command opens the output window; context menu title, icon and whether menu items show icons
- **Terminal** — scan, add manually, pick the default, adjust launch arguments per terminal, test one, keep the terminal open after a command finishes
- **Editors** — scan, add manually, toggle folder support, add to menu
- **New File** — manage templates
- **Configuration** — export / import (append or replace), file location, restore examples
- **Extension** — status and troubleshooting

Group settings live with the groups: click a group title in the main sidebar or the sort window to open its popover (enabled, title, icon, use the shared submenu).

### Background

The Finder extension is sandboxed and cannot spawn external processes, so a non-sandboxed process has to execute commands. "Not resident" therefore means "cold launch every time" — there is no third option. **Settings › General › Background** picks where on that trade-off you sit:

| Mode | Menu bar icon | Response | Leaves a process |
|---|---|---|---|
| **Stay in menu bar** (default) | yes | fastest | yes |
| **Stay running, hide icon** | no | fastest | yes |
| **Quit when idle** | no | ~0.08 s slower | no |

*Quit when idle* waits until nothing is running and no window is open before exiting, so a long background command is never cut short.

With the icon hidden, open the interface by double-clicking SwiftRight in Applications.

---

## Troubleshooting

**Nothing appears in the context menu**

1. If you downloaded a release build, did you remove the quarantine flag? A quarantined bundle is never registered — see [Gatekeeper](#gatekeeper)
2. Is the app in `/Applications` and has it been opened at least once? Only then does the system register the extension
3. Is SwiftRight enabled in System Settings? (the app's sidebar has a live status light)
4. `killall Finder`

**A group doesn't show up**

Click its title and check *Enabled (shown in the context menu)*. Disabled groups are dimmed in the sidebar and the sort window.

**Do I need to restart Finder after editing a command?**

No. The extension checks `commands.json`'s modification time on every right-click.

**Signing**

`DEVELOPMENT_TEAM` in `project.yml` needs to be your own team ID:

```bash
security find-identity -v -p codesigning
```

Note that the ten characters in parentheses of the certificate's common name are the *certificate* ID, not the team ID — read the `OU` field instead.

---

## Layout

```
project.yml                  XcodeGen definition (the .xcodeproj is committed too)
Shared/                      compiled into both the app and the extension
  SRCommand.swift              command model, group settings + menu matching
  SRConfigStore.swift          commands.json I/O + built-in examples
  SRPaths.swift                real paths, bypassing the sandbox container
  SRPlaceholder.swift          placeholder expansion + shell quoting
  SRTicket.swift               one-shot extension → app ticket
App/                         host app (not sandboxed)
  SwiftRightMain.swift         entry point, menu bar, URL callback, background residency
  SRCommandRunner.swift        Process execution, environment, timeout, terminal modes
  SRRunSession.swift           observable state of one run + incremental UTF-8 decoding
  SRAppModel.swift             UI data source, group actions and command generators
  SRPreferences.swift          language / theme / residency / localization
  SRWindowManager.swift        windows and the .accessory ⇄ .regular activation policy
  SRTerminal*.swift            terminal catalog and launch recipes
  SREditor*.swift              editor catalog
  SRFileTemplate.swift         new-file templates
  SRTemplateStore.swift        template persistence
  Views/                       SwiftUI, including group editor, sort, settings and about
FinderExtension/             Finder extension (sandboxed)
  FinderSync.swift             monitored scope, menu building, click forwarding
docs/                        README screenshots and icon
Scripts/
  build.sh                     build → install to /Applications → register the extension
  package.sh                   build → ad-hoc re-sign → dist/ zip + dmg
  make-icon.swift              generate the app icon
```

---

## License

[MIT](LICENSE)
