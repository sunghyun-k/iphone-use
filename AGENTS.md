# AGENTS.md

Guide for anyone changing the **code** of this repository: coding agents and human contributors
alike. If you want to *operate a phone* with the tool, read [`skills/iphone-use/SKILL.md`](skills/iphone-use/SKILL.md)
instead.

## Essentials

The rules that bite first. Details are in the sections below.

1. **Branch:** work on `dev` (a fresh clone checks out `main`, so `git switch dev`). PRs target
   `dev`. Never commit to `main`; only `scripts/release.sh` moves it.
2. **Language:** reply in the user's language; write code, comments, docs and commits in English.
3. **Odd code:** before changing it, read the `PITFALLS #N` entry it cites in `docs/PITFALLS.md`.
4. **Real devices are personal devices:**
   - pass `--udid`
   - look at the screen before any input
   - never approve prompts
   - restore what you change
5. **Output is an interface:**
   - `SKILL.md` quotes command output, so changing output means updating `SKILL.md` and a minor
     version bump.
   - Connection errors must say "connection" or "tunnel".
6. **Don't commit or push unless asked.**

## Language

- **Reply to the user in the user's language.** If they write in Korean, answer in Korean.
- **Write everything that lands in the repository in English**: code comments, doc comments, CLI
  help, printed output, error messages, Markdown docs and commit messages.
- Keep a non-English string literal only when the code compares it against what the device shows or
  types, such as Hangul jamo tables or localized UI labels. Add a short English comment saying why it
  stays.

## What this is

A CLI built by reverse-engineering the private stack behind Xcode's Device Hub and Accessibility
Inspector. There is no public API, so **observation, not documentation, is the source of truth.**
[`docs/PITFALLS.md`](docs/PITFALLS.md) records why things are the way they are, as numbered entries
that code comments cite as `PITFALLS #N`. **Read the relevant entry before "fixing" code that looks
odd.** Most of those spots have already burned someone once.

## Build and run

```sh
swift build                       # only dependency: swift-argument-parser
./.build/debug/iphone-use --help
```

There is no test suite. **Verification happens on a real device** (see below). A clean
`swift build` is the minimum bar for every change.

## Layout

```
Sources/iphone-use/
  Entry.swift        Entry point. Forwards argv to a running daemon, otherwise parses here
  IPhoneUse.swift    Subcommand registration + the shared --udid option
  Commands/          One file per subcommand (keep them thin; logic lives below)
  Remote/            CoreDevice path: tunnel, RemoteXPC, HID, screenshots, clipboard
  Daemon/            Resident mode: connection reuse + Unix-socket RPC
  AXSession.swift    Accessibility path: DTX session (kept open by the daemon)
  AXWire.swift       axAuditDaemon wire format (wrapping/unwrapping envelopes)
  AXWalker.swift     Moving focus + measuring element rects from the green focus box
  UIScreen.swift     Basis of ui/press/type/back: @e ref lists, walking to an element, post-action diff
  TextRecognizer.swift  Screenshot OCR (Vision). Only detects whether the on-screen keyboard is up; never picks targets
  ScreenGrid.swift   Named grid for screenshot --grid and cell math for touch/swipe --cell
  HangulKeys.swift   Hangul -> Dubeolsik key positions (text/type)
Sources/CMobileDevice/  C bindings for MobileDevice.framework
Sources/CDTXBridge/     Objective-C bridge to DTXConnectionServices
skills/iphone-use/SKILL.md          Agent-facing usage guide (see "Skill changes")
skills/iphone-use/scripts/iphone-use  Wrapper that finds or builds the CLI (see "Distribution")
bin/iphone-use          Claude Code puts a plugin's bin/ on PATH; forwards to the wrapper
.claude-plugin/         plugin.json + marketplace.json (this repo is its own marketplace)
scripts/release.sh      Cuts a release (see "Releasing")
docs/PITFALLS.md        Numbered reverse-engineering notes and dead ends
```

The two paths are **independent**:

- Screen and input go through the CoreDevice RemoteXPC tunnel.
- Accessibility goes through a lockdown service plus DTX. Over USB it is opened via MobileDevice;
  over Wi-Fi it goes through `.shim.remote` inside the tunnel.

Changing one path doesn't touch the other.

Device-specific traps:

- **USB and Wi-Fi share the same code.** Many timing bugs only showed up on Wi-Fi (PITFALLS #15–22).
  If you touch input, connection or teardown ordering, test on Wi-Fi too.
- **The iPad's touch panel has a different orientation from its framebuffer** (PITFALLS #23). If you
  touch coordinate conversion, test on an iPad.
- **Keyboard layouts differ per device** (PITFALLS #11). If you change typing, try it on devices with
  different layouts.
- **`MobileDevice` (`DeviceDiscovery`) only sees USB devices.** Don't use it for device lookup in new
  code.

## Conventions

- **Comments explain why, not what.** The most useful comment says what breaks if the code is done
  the obvious way ("without this, X happens"). When you discover such a thing, add a pitfall entry and
  cite it.
- **Don't link private frameworks; `dlopen` them.** The binary must start even without Xcode or with
  a different version. Failures must surface as runtime errors.
- **New subcommands** go in `Commands/` and are added to the list in `IPhoneUse.swift`.
- **For a device connection**, don't construct `RemoteServiceDiscovery` directly. Use
  **`SessionPool.rsd(udid:)` / `SessionPool.release(_:)`** so the daemon can reuse it.
- **Write output with `print` to stdout.** The daemon swaps file descriptors to capture it.
- **Output format**:
  - Machine-readable output is JSON. Human-readable output is a one-line summary.
  - Error messages tell the reader what to do next. Agents follow them literally.
- **Connection-failure messages must contain "connection" or "tunnel".** The daemon drops its
  cached session when it sees those words (`DaemonCommand.swift`).
- **Keep private data out of the repository**: no real names, SSIDs, device names, message contents
  or third-party app specifics in comments, docs, examples or commit messages. Use generic examples
  and Apple's built-in apps.

## Adding a feature

Every CoreDevice feature name is baked into the host binary:

```sh
# Callable feature names (~90)
strings -a /Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities \
  | grep -oE 'com\.apple\.coredevice\.feature\.[A-Za-z0-9.]+' | sort -u

# Input/output shapes come from the Swift symbols
nm -U /Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities \
  | grep -oE '_\$s[A-Za-z0-9_]*' | xargs -n1 swift demangle --compact | grep -i '<what you want>'

# Services the device actually advertises (stalls HID input for a while afterwards, PITFALLS #15)
./.build/debug/iphone-use hid-info | jq .services
```

Some features have several **actions** underneath, such as get and set for settings. Action names are
in the same binary:

```sh
strings -a .../CoreDeviceUtilities | grep -oE 'com\.apple\.coredevice\.action\.[A-Za-z0-9.]+' | sort -u
```

Then poke it with `invoke`. Error messages usually give the next clue: "dictionary required here" plus
`NSCodingPath` names the wrong field.

```sh
./.build/debug/iphone-use invoke <service> <feature> --input '{"key":"value"}'
./.build/debug/iphone-use invoke <service> <feature> --action <action> --input '{...}'
./.build/debug/iphone-use invoke <service> --no-envelope --input '{"command":"PULL"}'
```

Without an action, a feature usually runs its get, and **unknown input keys are silently ignored**.
If a set "succeeds" but nothing changes, suspect the action first. That same property makes it safe
to read the current value: send a single unknown key.

**If no reply comes at all**, the only view into what happened is the device log.
`LockdownShim.open("com.apple.syslog_relay", rsd:)` gives the raw syslog stream (line-oriented text
after check-in). It contains personal data, so:

- Narrow it down by process name and look only at the lines you need.
- Never save it wholesale, and never paste it anywhere.

Once the shape is clear, add a typed wrapper under `Remote/` and put a subcommand on top of it.

## Verifying on a real device: rules you must follow

A connected phone or tablet is usually **someone's personal device**, with messaging and banking apps
on it.

- **If several devices are connected, the owner decides which one to test on.** Always pass `--udid`.
- **Look at the current screen (`ui` or `screenshot`) before any input.** The owner may have just been
  using another app. If the screen isn't what you expected, stop and ask.
- **Back up the clipboard before `paste`** (`clipboard -o`) and restore it afterwards
  (`paste --clipboard-only --file`). Handle the contents only through files; never print them into
  logs.
- **Never approve a permission or consent prompt** (paste permission and so on) on the owner's behalf.
  Decline it or hand it to the owner.
- **Restore anything the owner would notice**: input source, volume, brightness, settings. If you
  can't restore something, say so.
- **Never call `DisplayService.stop_all_streams` or anything like it.** It wedges the device's media
  daemon until a reboot. Media streams aren't needed at all.
- **Never overlap focus moves** (`scan`, `ui`, `press`). Overlapping moves break the AX daemon for the
  rest of the session. One at a time.
- **Don't record private data you see on screen** (message previews, codes, account details)
  anywhere, including chat.
- **Destructive actions** (delete, send, report, purchase) only when the owner explicitly names the
  target.

## Skill changes: verify with a subagent

`skills/iphone-use/SKILL.md` exists so that an agent can operate a device **from that document alone**. When you
change a command or that document:

1. Give a subagent a real task and don't let it read the source. Use a small model if you can.
2. Have it report where it got stuck, then fix the command or the doc.
3. Keep the task read-only: no settings changes, no permission prompts, no personal apps.
4. Run **one subagent at a time**. Two agents on the same device wreck each other's screen.

## Working on the daemon

- **Don't keep it alive indefinitely.** The daemon holds a pairing assertion; the default is to exit
  after 10 idle minutes.
- **If a connection may be damaged, call `SessionPool.drop()`** so the next request opens a fresh
  one.
- **Commands that must not go through the daemon** are listed in `DaemonClient.localOnly`.
- **While debugging, bypass the daemon** with `--no-daemon` or `IPHONE_USE_NO_DAEMON=1`.
- **Debug environment variables:** `IU_DTX_DEBUG=1` dumps DTX messages; `IU_DTX_TEE=1` logs raw
  socket byte counts.
- **You don't need to restart it after a rebuild.** Requests carry the client's build stamp, and a
  stale daemon exits (PITFALLS #28).

## Distribution

We ship source, not binaries. Users need Xcode at runtime anyway, so a local build avoids code
signing, notarization and universal builds.

- **Claude Code plugin.** `.claude-plugin/marketplace.json` lists this repository itself (`"source":
  "./"`). The plugin's `bin/` is put on `PATH`, and `bin/iphone-use` forwards to the skill's wrapper.
  The whole repository is installed, so the wrapper builds from the source next to it.
- **`npx skills`.** Only `skills/iphone-use/` is copied. The wrapper clones the tag `v<version>` and
  builds that.
- **Wrapper lookup order:**
  1. `IPHONE_USE_BIN`, or a non-script `iphone-use` on `PATH` whose `--version` matches (a different
     version would contradict `SKILL.md`)
  2. `~/.cache/iphone-use/<version>/iphone-use`
  3. Build from the enclosing repository
  4. Clone the tag and build (no fallback to the default branch)

  Keep it POSIX `sh`. A cached build is keyed by version only, so **every release needs a new
  version**, or users keep the old binary.
- **Testing an install locally:**
  - Plugin: `claude plugin marketplace add "$PWD"`, then `claude plugin install iphone-use@iphone-use`.
  - `npx skills`: in a scratch directory, `npx skills add <path to repo> -a codex -y --copy`.
  - Use `rm -rf ~/.cache/iphone-use/<version>` to force a rebuild.

## Releasing

**`main` is the release channel.** Plugin and `npx skills` installs both read the default branch,
so anything on `main` reaches users immediately. Development happens on `dev`. `main` only moves
forward to a release commit, and it is never committed to directly.

**Versioning** (semver, while 0.x):

- **Patch** (`0.1.1`): fixes that don't change commands, options or output.
- **Minor** (`0.2.0`):
  - new commands or options
  - any change to output or error wording that `SKILL.md` quotes or agents rely on
  - removals (before 1.0, breaking changes go here)

Update `SKILL.md` in the same release as the behavior it describes.

**Before releasing**, on `dev`:

1. `swift build` is clean, and `SKILL.md` matches the commands.
2. Install both ways locally (see "Distribution") and run `ui` and `press` once on a real device.
3. If commands or `SKILL.md` changed, run the source-blind subagent check ("Skill changes").

**Cut it** with `scripts/release.sh <version>`. It:

1. refuses unless you're on `dev` with a clean tree and `main` is an ancestor of `dev`
2. bumps the version in all four places (`IPhoneUse.swift`, `plugin.json`, `marketplace.json`,
   `VERSION` in the wrapper)
3. runs a release build and checks `--version`
4. runs `claude plugin validate .`
5. commits "Release v<version>"
6. fast-forwards `main` to it, tags `v<version>` and switches back to `dev`

If the script stops partway (build or validation failed), it restores the version files. Fix the
problem on `dev` and run it again.

**It never pushes.** Publish `main` and the tag together in one push:

```sh
git push --atomic origin dev main v<version>
```

Pushing `main` without the tag breaks `npx skills` installs until the tag arrives, because the
wrapper refuses to build anything but the tag.

## Pitfall notes

When you learn something by observation that the code depends on:

1. Add an entry at the end of `docs/PITFALLS.md` with the next number. Never renumber.
2. Say what you tried, how it broke, and what the code does now.
3. Cite it from the code as `PITFALLS #N`.

## Commits and pull requests

- **Agents: don't commit or push unless asked.**
- **Work on `dev`.** The maintainer commits directly to `dev`; contributors open pull requests
  against `dev`. Never commit to `main`; only `scripts/release.sh` moves it (see "Releasing").
- **Commit message format:**
  - Subject: one line, in English, imperative, saying what now works or what changed
    ("Measure element rects correctly while a video plays").
  - Body: the changes, as bullet points.
  - Non-obvious reasoning goes in code comments and `docs/PITFALLS.md`. The message just points to
    them.
- **Before committing, remove investigation leftovers**:
  - code marked `TEMP`
  - newly added `IU_*` debug environment variables
  - temporary subcommands

  `IU_DTX_DEBUG` and `IU_DTX_TEE` are documented features and stay.
- **Don't commit** screenshots, device logs, or anything captured from a personal device.
