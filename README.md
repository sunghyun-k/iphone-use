# iPhone Use

A macOS command-line tool for seeing, controlling and reading the accessibility tree of a **real
iPhone or iPad** connected over USB or Wi-Fi. It is not a simulator tool.

It is built for AI agents. `ui` returns the screen as a numbered, text-only list of elements.
`press @e12` taps element 12 and reports what changed. The agent can work a phone without looking
at screenshots. When accessibility isn't enough, screenshots with a labelled grid and coordinate
touches are there too.

iphone-use runs on the same private stack that Xcode's **Device Hub** and **Accessibility Inspector**
use. It needs no entitlements, no `sudo`, no app on the device and no WebDriverAgent. It needs only a
paired device with Developer Mode on.

> **Status:** experimental. The tool depends on undocumented Apple services that can change with any
> Xcode or iOS release. Verified on an iPhone (iOS 27.2, over Wi-Fi) and an iPad (iPadOS 26.6, over
> USB, in landscape) with Xcode 27.

```console
$ iphone-use ui
# Preferences
@e1	Settings, Heading
@e2	Apple Account, iCloud+ and more, Button
@e5	Airplane Mode, 0, Button, Toggle
@e12	General, Button
…
(more — ui --more)

$ iphone-use press @e12
Pressed @e12 General, Button
New screen — Preferences
@e1	Settings, Button
@e2	General, Heading
…
```

Element descriptions are what VoiceOver would read, in the device's language.

## Requirements

- macOS with **Xcode** installed. iphone-use uses the frameworks at the path `xcode-select -p`
  reports.
- A device on **iOS 17 or later** for full control. On iOS 16 and earlier only `ui` and `scan`
  (reading) work, because those devices have no CoreDevice tunnel.
- Swift 6 toolchain to build. The only dependency is `swift-argument-parser`.

## Device setup (once per device)

1. Connect the device to the Mac over USB and accept **Trust This Computer**.
2. Turn on **Developer Mode** on the device: Settings › Privacy & Security › Developer Mode, then
   restart and confirm. The menu only appears after the device has been connected to Xcode once. If
   Device Hub shows "Enable Developer Mode", this step isn't done yet. `devices` will still list
   the device, but the screen and input services won't open.
3. After pairing, the device also works over **Wi-Fi** on the same network, without the cable.

Keep the device unlocked with the screen on while you use it.

## Install

**Claude Code plugin.** This installs the skill and puts `iphone-use` on the agent's `PATH`:

```
/plugin marketplace add sunghyun-k/iphone-use
/plugin install iphone-use@iphone-use
```

**Codex, Cursor and other agents.** Use the [skills CLI](https://github.com/vercel-labs/skills):

```sh
npx skills add sunghyun-k/iphone-use
```

Both options ship source, not a prebuilt binary. On first use, the skill's wrapper
(`skills/iphone-use/scripts/iphone-use`) builds the CLI with `swift build -c release` into
`~/.cache/iphone-use/<version>/`. That takes about a minute; later runs start instantly. A real
`iphone-use` already on `PATH` always wins.

**CLI only, from source:**

```sh
git clone https://github.com/sunghyun-k/iphone-use.git && cd iphone-use
swift build -c release
cp .build/release/iphone-use /usr/local/bin/    # or anywhere on PATH
```

For development, `swift build && ./.build/debug/iphone-use --help`.

## Quick start

```sh
iphone-use devices                        # name, UDID and connection (usb / wifi)
iphone-use daemon &                       # optional; keeps connections warm (0.25 s -> 0.03 s per command)

iphone-use ui                             # first 20 elements, `ui --more` for the next page
iphone-use ui --find "Search"             # only elements whose description contains the text
iphone-use press @e12                     # tap; prints the new screen or only what changed
iphone-use type @e36 "Battery"            # tap a text field and type
iphone-use back                           # back button, else an edge swipe
iphone-use home

iphone-use launch Settings                # app name or bundle ID
iphone-use open "prefs:root=General"      # deep link / URL
iphone-use screenshot -o screen.png --grid --max-width 800
iphone-use touch --cell G21               # tap the middle of grid cell G21
```

With more than one device, pass `--udid <UDID or name>` to every command, for example
`--udid "Home iPad"`. If you leave it out, the command fails and lists the candidates.

## Commands

| Area | Commands | Notes |
|---|---|---|
| Read & act via accessibility | `ui`, `press`, `type`, `back`, `home` | Refs (`@eN`) instead of coordinates. After each action it waits for the screen to settle and prints a diff. `press` also has `--hold`, `--trailing` (row-end ⓘ buttons), `--action` and `--swipe` (reveal swipe actions such as Delete). |
| Apps | `apps`, `launch`, `open` | Launch by display name or bundle ID. Open any URL or deep link. |
| Device settings | `settings`, `location` | Appearance, text size and accessibility toggles; simulated location. These are the same controls as Device Hub's settings panel. |
| Screen & coordinates | `screenshot`, `wait`, `touch`, `swipe`, `scroll`, `text`, `key`, `button`, `paste`, `clipboard` | For screens with poor accessibility. `screenshot --grid` draws named cells so you can tap by cell instead of guessing pixels. |
| Raw accessibility | `scan`, `attr` | Walks the whole focus order. The screen may scroll while it does. |
| Diagnostics | `devices`, `daemon`, `hid-info`, `invoke`, `ax-probe`, `dtx-introspect` | `invoke` calls any CoreDevice feature by name, for exploration. |

Run `iphone-use <command> --help` for the options of each command.

### Using it from an AI agent

[`skills/iphone-use/SKILL.md`](skills/iphone-use/SKILL.md) is a self-contained guide for agents. It
covers the basic `ui` → `press` loop, how to read results, when to fall back to screenshots, and
safety rules. The plugin and `npx skills` install it for you (see [Install](#install)).

## How it works

Device Hub and Accessibility Inspector reach the device over **two independent paths**. DeviceHub.app
doesn't link a single accessibility framework (`otool -L`). iphone-use implements both paths itself
and combines them.

| | Screen & input | Accessibility tree |
|---|---|---|
| Transport | CoreDevice RemoteXPC / RSD tunnel | DTXConnectionServices: lockdown over USB, lockdown shim inside the tunnel over Wi-Fi |
| Device service | `com.apple.coredevice.*` | `com.apple.accessibility.axAuditDaemon.remoteserver` |
| Host framework | `CoreDeviceMediaStreamSupport`, `UniversalHID` | `AccessibilityAudit`, `MobileDevice` |
| Code | `Sources/iphone-use/Remote/` | `Sources/CDTXBridge/`, `AXSession.swift` |

**From tunnel to touch.** `devicectl` doesn't expose HID. CoreDevice's HID API is pure Swift with no
`.swiftmodule`, so it can't be bound dynamically. iphone-use therefore speaks RemoteXPC directly:

1. **Tunnel.** Creating a utun needs root. Instead, iphone-use asks the stock
   `com.apple.CoreDevice.remotepairingd` over libxpc (`RemotePairing.CreateAssertionCommand`) for the
   address of the tunnel Apple has already opened. This needs no root, doesn't stop `remoted`, and
   coexists with Xcode.
2. **RSD port.** This is the remote port of `remoted`'s TCP connection to the tunnel address, found
   with `nettop`.
3. **Transport.** HTTP/2 over plain TCP that ignores standard semantics. HEADERS frames are empty,
   there is no HPACK, and everything travels in DATA frames as XPC envelopes. That is why the
   frames are built by hand.
4. **HID.** Raw HID reports go to `com.apple.coredevice.hid.universalhidservice`: touchscreen service
   257 and keyboard 512. Hardware buttons go through `com.apple.coredevice.hid.indigo`.

**Finding elements without coordinates.** The accessibility protocol gives no element frames. `ui`
and `press` walk the Accessibility Inspector focus to the target. They then measure the **green focus
box** the device draws around it, by diffing a screenshot with the box against one without. That
rect is where the tap goes.

**Runtime binding.** Private frameworks are opened with `dlopen`, never linked. The binary still starts
when Xcode is missing or a different version, and a missing symbol becomes a runtime error.

The details, including every dead end, are in [`docs/PITFALLS.md`](docs/PITFALLS.md). Read it before
changing code that looks strange; most of it is there for a reason.

## Limitations

- **Keyboard layout is fixed per device.** HID sends key positions, and the device decodes them with
  its own layout, regardless of the input source. `type`/`text` handle ASCII and Hangul (mapped to
  Dubeolsik keys). Other text goes through `paste`, which makes the device show a paste-permission
  prompt every time.
- `ui` moves accessibility focus like VoiceOver, so the screen can scroll a little. A `press` takes
  about 5–8 s.
- Accessibility Inspector attached to the same device starves `ui`/`scan`.
- Some screens have little accessibility (games, canvases, some web content). Use `screenshot --grid`
  and `touch --cell` there.
- No screen streaming. Screenshots were enough.

## Contributing

Development happens on the `dev` branch; please open pull requests against `dev` (`main` only holds
releases). See [`AGENTS.md`](AGENTS.md) for the layout, conventions and how to verify changes on a
real device. It applies to human contributors and coding agents alike.

## License

[MIT](LICENSE)

## Disclaimer

This project is not affiliated with or endorsed by Apple. It relies on private, undocumented
interfaces shipped with Xcode. Use it on devices you own or are authorized to control.
