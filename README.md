# iPhone Use

A macOS command-line tool for seeing and controlling a **real iPhone or iPad** connected over USB or
Wi-Fi. It is not a simulator tool.

It is built for AI agents. `ui` takes a screenshot, reads its text on the Mac with Vision OCR, and
returns every line as a numbered list, with the screenshot saved next to it under a labelled grid.
`press @t5` taps line 5 and reports what changed. Icons and toggles are tapped by grid cell
(`touch --cell G21`).

iphone-use runs on the same private stack that Xcode's **Device Hub** uses. It needs no
entitlements, no `sudo`, no code signing, no app on the device and no WebDriverAgent. It needs only a
paired device with Developer Mode on.

> **Status:** experimental. The tool depends on undocumented Apple services that can change with any
> Xcode or iOS release. Verified on an iPhone (iOS 27.2, over USB) with Xcode 27.

```console
$ iphone-use ui
23 text lines
@t1	Settings	B2
@t2	Search	C3
@t3	Apple Account	C5
@t9	General	C12
…
Screenshot: ~/.iphone-use/screen-<udid>.png (grid cells as in the third column; icons without text: touch --cell)

$ iphone-use press @t9
Pressed @t9 "General"
New screen — 17 text lines
@t1	Settings	A2
@t2	General	E2
…
```

Each line is the text OCR read, in the device's language, and the grid cell of its center.

## Requirements

- macOS with **Xcode** installed. iphone-use uses the frameworks at the path `xcode-select -p`
  reports.
- A device on **iOS 27 or later**.
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

iphone-use ui                             # text lines on screen + gridded screenshot
iphone-use ui --find "Search"             # only lines containing the text
iphone-use press @t9                      # tap; prints the new screen or only what changed
iphone-use type @t2 "Battery"             # tap a text field and type
iphone-use scroll down                    # prints the new list
iphone-use home

iphone-use launch Settings                # app name or bundle ID
iphone-use open "prefs:root=General"      # deep link / URL
iphone-use touch --cell G21               # tap the middle of grid cell G21 (icons, toggles)
```

With more than one device, pass `--udid <UDID or name>` to every command, for example
`--udid "Home iPad"`. If you leave it out, the command fails and lists the candidates.

## Commands

| Area | Commands | Notes |
|---|---|---|
| Read & act on text | `ui`, `press`, `type`, `home` | OCR text lines with refs (`@tN`) and a gridded screenshot. After each action it waits for the screen to settle and prints a diff. `press` checks the line is still there before tapping, and also has `--hold`, `--trailing` (row-end ⓘ buttons and toggles) and `--swipe` (reveal swipe actions such as Delete). |
| Apps | `apps`, `launch`, `open` | Launch by display name or bundle ID. Open any URL or deep link. |
| Device settings | `settings`, `location` | Appearance, text size and accessibility toggles; simulated location. These are the same controls as Device Hub's settings panel. |
| Screen & coordinates | `screenshot`, `wait`, `touch`, `swipe`, `scroll`, `text`, `key`, `button`, `paste`, `clipboard` | For icons and anything without text. Grid cells let you tap by name instead of guessing pixels. `touch`, `swipe` and `scroll` print the new list too. |
| Diagnostics | `devices`, `daemon`, `hid-info`, `invoke` | `invoke` calls any CoreDevice feature by name, for exploration. |

Run `iphone-use <command> --help` for the options of each command.

### Using it from an AI agent

[`skills/iphone-use/SKILL.md`](skills/iphone-use/SKILL.md) is a self-contained guide for agents. It
covers the basic `ui` → `press` loop, how to read results, when to look at the screenshot, and
safety rules. The plugin and `npx skills` install it for you (see [Install](#install)).

## How it works

Screens are captured with `com.apple.coredevice.screencaptureservice` and read on the Mac with Vision
(`VNRecognizeTextRequest`). Touches and keys go to the device's HID services. Both live in
`Sources/iphone-use/Remote/`.

**From socket to touch.** `devicectl` doesn't expose HID. CoreDevice's HID API is pure Swift with no
`.swiftmodule`, so it can't be bound dynamically. iphone-use therefore speaks RemoteXPC directly:

1. **Socket.** iphone-use never talks to the device's RSD itself. A second RSD peer displaces
   macOS's `remoted`, and Xcode then loses the device until it is replugged. Instead it asks the
   stock `CoreDeviceService` over libxpc, as `devicectl` does, for a usage assertion and then a
   connected socket per service (`com.apple.coredevice.action.createservicesocket`). No root, no
   entitlements, and Xcode keeps building and running on the same device.
2. **Lockdown services.** `installation_proxy` is a lockdown service. Over USB they
   are started with MobileDevice; otherwise iphone-use falls back to the `.shim.remote` copy.
3. **Transport.** HTTP/2 that ignores standard semantics. HEADERS frames are empty,
   there is no HPACK, and everything travels in DATA frames as XPC envelopes. That is why the
   frames are built by hand.
4. **HID.** Raw HID reports go to `com.apple.coredevice.hid.universalhidservice`: touchscreen service
   257 and keyboard 512. Hardware buttons go through `com.apple.coredevice.hid.indigo`.

**Text, not guesses.** OCR once picked targets from a string the agent guessed, and pressed the wrong
place when the guess matched several lines or a misread one. `ui` instead lists every line it read
with a ref, so the agent picks a line it has seen. Before tapping, `press` checks that the pixels
around the line still look the same, and otherwise looks the line up again by its text.

**Runtime binding.** Private frameworks are opened with `dlopen`, never linked. The binary still starts
when Xcode is missing or a different version, and a missing symbol becomes a runtime error.

The details, including every dead end, are in [`docs/PITFALLS.md`](docs/PITFALLS.md). Read it before
changing code that looks strange; most of it is there for a reason.

## Limitations

- **Keyboard layout is fixed per device.** HID sends key positions, and the device decodes them with
  its own layout, regardless of the input source. `type`/`text` handle ASCII and Hangul (mapped to
  Dubeolsik keys). Other text goes through `paste`, which makes the device show a paste-permission
  prompt every time.
- `ui` lists only text. Icons, toggle states and images are in the saved screenshot; tap them with
  `touch --cell`.
- OCR reads Korean and English. Other scripts may come out garbled.
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
