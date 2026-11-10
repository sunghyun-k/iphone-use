# Pitfalls and reverse-engineering notes

Everything here was observed directly on real devices. None of it is in public documentation,
because there is none. Code comments cite these entries as `PITFALLS #N`.

**If some code looks odd, read the entry it cites before "fixing" it.** Most of these spots have
already broken once.

## How this file works

- **Entries are in the order they were found**, not by topic. Use the index below to find the
  entries on a topic.
- **Numbers never change**, because comments point at them. Add a new entry at the end with the next
  number.
- **An entry says** what was tried, how it broke, and what the code does now. When a later entry
  changes the picture, add a short note to the old one that points to it; don't rewrite history.
- **Some numbers are missing here.** #1–4, #35–41, #43, #45 and #47 belong to the accessibility path
  that OCR replaced (#48). They are in [`PITFALLS-archive.md`](PITFALLS-archive.md).
- A few entries mention commands that were removed later (`find`, `back`). The findings still explain
  today's code.
- Keep private data out: no real names, account details or third-party app names. Say "a messenger
  app".

## Index by topic

| Topic | Entries |
|---|---|
| Connection, tunnel, sharing the device with Xcode | #19, #20, #26, #27, #44, #55 |
| Daemon | #28, #50, #62 (dead cached tunnel), #67 (keeping the device awake), #71 (relative paths) |
| CoreDevice services and features (finding them, envelopes, get/set) | #12, #14, #21, #22 |
| DTX (Instruments, used to revive a stuck launch daemon) | #5, #6, #7, #20 |
| Apps and URLs | #20, #21, #29, #65 (a name with a dot), #73 (restart) |
| Screenshots and waiting for the screen to settle | #13, #25, #34, #49, #69 |
| Touch coordinates, panels and the grid | #8, #9, #10, #23, #51, #53 |
| HID delivery and timing (lost taps and keys) | #15, #16, #17, #18, #50, #54 |
| Scrolling and swipes | #24, #31, #33 |
| Typing: layouts, Hangul, on-screen keys, paste | #11, #18, #30, #32, #58, #63, #64, #68 |
| Telling a keyboard from a keypad or a calendar; the suggestion bar | #31, #61, #63, #64, #65 |
| Reading the screen: OCR lines, status items, the diff after an action | #48, #56, #62, #63, #64, #65, #66 |
| Controls without text: switches, symbols, buttons by shape | #52, #59, #60, #61, #62, #63, #64, #65, #72 |
| State read from pixels: check boxes, selection, sliders, page dots, popups | #66, #70 |
| Naming icons with the on-device model | #57 |
| Pressing the right thing (moved rows, banners, cell snapping) | #42, #46, #59, #61 |
| iPad | #11, #23, #56 |
| Foldable iPhone | #51, #53 |

## Known gaps

Open problems, with the entry that describes each:

- The HID keyboard's layout can't be chosen; what the keys type depends on the device and the app
  (#11, #58, #64). Tapping the on-screen keys covers an iPhone held upright only (#64).
- Touch rotation is unverified for an iPad held in portrait and for `rot180` (#23, #51).
- A notification banner still takes a tap near the top; the guard was not merged (#46).
- Icons on a glass bar over a photo or video aren't found, and text behind a glass bar reads as
  noise (#52, #64).
- A slider at 0% or 100% has no line, nor does a picker wheel's selected value (#63, #66).
- A popup or a tip overlay is only noticed over a dimmed light page: not in dark mode, not a system alert (#66, #70).
- A check box whose states differ only in color, and a selection shown only by weight, aren't
  read (#66).
- Do Not Disturb can't be turned on by a command, so notification banners still need the user
  (#67, #46).
- The passcode screen captures as black, so it's reported as "screen is off" (#63).
- A custom-drawn control can get a wrong symbol name (#64). Home-screen icon artwork gives `[icon]`
  lines (#62).
- There is no pinch gesture (#64).

## Trust and entitlements

DeviceHub.app has **empty** entitlements. All trust is handled by the pairing record and the
`CoreDeviceService` daemon. `axAuditService.xpc` holds
`com.apple.private.accessibility.remoteDeviceContent` and others, but the device side has no way to
verify host entitlements (lockdown/DTX carry no code-signing information), so that is only a local
macOS gate. In practice a bare client can read everything.

## Entries

### 5. `_setDispatchValidator:` is not what its name suggests

It is not a `BOOL (^)(SEL)` that allows or denies. It is **`NSSet<Class> * (^)(NSInvocation *)`**:
it returns the secure-coding allowlist used to deserialize the arguments, and DTX swaps that return
value in place of `[DTXMessage defaultAllowedSecureCodingClasses]`
(`-[DTXMessage invokeWithTarget:replyChannel:validator:]` @0x1817c).
Returning `YES` crashes immediately in `objc_retain(0x1)`. Not installing a block at all makes DTX
check against its global selector registry and throw an NSException, and the event is silently lost.

### 6. Channel callbacks live in one struct

`_channelGuarded` = {userDispatchQueue, dispatchTarget, messageHandler, dispatchValidator}, and
`setMessageHandler:` clears the queue. Always install them in this order: `setMessageHandler:` →
`_setDispatchTarget:queue:` → `_setDispatchValidator:`.

### 7. Disassemble the arm64e slice

`otool -arch arm64` shows the wrong code. The `imp - dli_fbase` offset obtained from `dladdr`
matches the arm64e slice.

### 8. Touch coordinates are normalized to 0..65535

Not pixels, not points. Out-of-range coordinates are *silently dropped*: no error, no log, nothing
happens on screen, so it is easy to blame authentication or the report format instead. We lost a
lot of time feeding raw pixels (1290×2796). The CLI now reads the screen size from `getdisplayinfo`
and converts automatically.

### 9. There is no media-stream authentication gate (on this build)

pymobiledevice3 notes that "a video stream must be running for backboardd to accept digitizer
events", but on iOS 24B5084k touches go through with no stream at all. The `Authenticated` flag in
the surface list is not a gate indicator either: the touchscreen (257) lacks that flag even while
Device Hub is actively controlling the device.

### 10. Stream teardown wedges the device

After calling `DisplayService.stop_all_streams`, `devicectl device capture screenshot` stops
responding (a reboot clears it). We don't need a stream, so we never open one.

### 11. Keyboard sends key positions, and the layout is fixed per device

Later entries narrow this: the layout also differs per app on one device (#58, #64), and where the HID
keys type the wrong script, `type` taps the on-screen keys instead (#64).

Which character appears is decided by the layout the device attaches to the virtual keyboard
(surface 512), and that layout does not follow the input source. The iPhone (iOS 27.2) is always
Korean Dubeolsik, so `wifi` came out as Hangul syllables (the Hangul on those key positions); the iPad
(iOS 26.6) is always English, so the Dubeolsik keys `qoxjfl` came out literally as `qoxjfl`.
`ctrl+space`, Caps Lock, Globe (Consumer 0x29D) and LANG1/LANG2 (0x90/0x91) switch **only the
on-screen keyboard's language.** Typing on the Dubeolsik layout while an English input source is
active gives uncomposed jamo instead.

So `text` decomposes Hangul into Dubeolsik key positions (`HangulKeys`): on a device with a Korean
layout you get Hangul, on one with an English layout you get Latin letters. Digits and symbols sit
in the same positions on both layouts, so they work everywhere. Shift combinations land exactly
(`!`, `_`, `?`, and Shift+Q gives the doubled jamo).

There is no way to change the layout yet. CoreDevice has a `createService` that builds a new
keyboard surface with `HIDServiceDescriptor.keyboardCountryCode`; we tried it and got blocked
(iPadOS 26.6, Wi-Fi):
- The device's `dtuhidd` creates a fixed set of four surfaces **per universalhidservice connection**
  (button 0x402, avpCustom 0x500, keyboard 0x200, touchscreen 0x101) and deletes them when the
  connection closes (confirmed in the device syslog).
- Keyboard 0x200 has `DeviceUsagePairs` 0/0; its real usage (1/6, keyboard) is stored separately in
  `_CoreDevice_originalUsages`. It is marked as a "software keyboard" so the on-screen keyboard keeps
  showing while it is used. That looks like the reason it ignores the input source.
- Sending `createService` a 1/6 keyboard, and one shaped exactly like 0x200, both returned
  `serviceID 0` (rejected).

So for now the layout can't be changed, and characters not on the layout go in via `paste`
(permission prompt, #30) or a URL workaround.

### 12. All feature names are in the host binary

The services a device advertises come from `hid-info`; the feature names you can call on them are
baked into the host framework as strings:

```sh
strings -a /Library/Developer/PrivateFrameworks/CoreDeviceUtilities.framework/Versions/A/CoreDeviceUtilities \
  | grep -oE 'com\.apple\.coredevice\.feature\.[A-Za-z0-9.]+' | sort -u
```

That gives about 90. Input/output shapes show up when you demangle the Swift symbols in the same
binary (`nm -U ... | grep -oE '_\$s[A-Za-z0-9_]*' | xargs -n1 swift demangle`). For example, the
symbol `CaptureScreenshotInput.init(displayUniqueID:requestedFormat:)` tells you directly that the
input is `{"requestedFormat": "png"}`. The `invoke` command exists for this kind of probing.

### 13. Screenshots arrive as 16-bit PNG

One 1290×2796 capture is 10.8 MB. `png` is the only format; any other value gives a decoding error.
Re-encoding to 8-bit brings it to 348 KB, 31× smaller, and 16-bit precision is useless for a screen
capture. `screenshot` re-encodes by default.

### 14. The clipboard service is the only one without an envelope

`com.apple.coredevice.pasteboardservice` rejects messages wrapped in the CoreDevice envelope with
"Message missing command field"; it takes a raw `{command: "PULL"|"PUSH", ...}`. PUSH has no reply:
if you close the socket right after sending, the message vanishes before the device reads it,
silently. You must read it back with PULL to confirm, and since the device closes the connection
after handling PUSH, the connection can't be reused either. When the peer closes after a message
that has no reply, `write` kills the process with SIGPIPE, so `SO_NOSIGPIPE` is needed too.

### 15. The HID service drops the connection after replying, then goes quiet

#15–#22 were found over Wi-Fi. Wi-Fi uses the same path as USB (`remotepairingd` hands out tunnels for
Wi-Fi devices too); what differs is latency and packet timing, and that broke several things that only
worked on USB by luck.

Send `universalhidservice` a request that gets an answer (such as `connectedServices`) and the
device closes the connection right after replying, then ignores new handshakes for more than 10
seconds (looks like a launchd restart throttle). Run commands back to back and they all time out;
it takes minutes to clear. So nothing except `hid-info` uses answered requests.

### 16. Sync unanswered reports with a PING before closing

Touch and key reports get no reply. On USB we could send and close immediately, but on Wi-Fi the RST
arrived before the device read the data, and whole swipes or keystrokes disappeared (1–2 out of 6).
So both connections do one HTTP/2 PING round trip before closing: the device's HTTP/2 layer drains
frames in order, so once the ACK arrives, the earlier DATA is already out of the socket.

Closing politely with just a FIN is actually worse: the device's HID service then delayed the next
connection by nearly 10 seconds. The daemon keeps its connection open but still PINGs; otherwise a
`screenshot` right after a command captures the screen from before the input.

### 17. The home button needs a wait after release

The device waits a moment after release to tell a double click from a single one, and if the
connection closes in that window the press is cancelled (measured on Wi-Fi: at 0.3 s every press was
ignored, from 0.45 s they registered). Conversely, in the daemon, where the connection stays open,
the next press merges into a double press and opens the app switcher (it still merged at 0.55 s).
We wait 0.8 s after release.

### 18. Press modifiers separately first

If a modifier and a key share one report, the device sometimes misses the modifier: on Wi-Fi, ⌘V
went through the Korean layout and came out as the Hangul jamo on the V key. Send it the way a
person types: modifier → modifier+key → modifier → all released.

### 19. MobileDevice can't see Wi-Fi devices

`AMDeviceNotificationSubscribe` only reports USB devices. So lockdown services (installation_proxy
and the like) are opened on the port the device advertises in RSD as
`<name>.shim.remote`. Connect over TCP and send a lockdown-style plist (4-byte big-endian length +
XML) `{Request: RSDCheckin, Label, ProtocolVersion: "2"}`; two replies come back, `RSDCheckin` and
`StartService`, and every byte after that is the service's own wire protocol. The tunnel is already
encrypted, so there is no TLS (`LockdownShim.swift`).

`com.apple.instruments.dtservicehub`, despite the similar name, has **no check-in**: send one and it
disconnects immediately. It speaks DTX as soon as the port opens.

`devices` can list Wi-Fi devices thanks to `remotepairingd`'s `BrowseRequest`.

### 20. `devicectl` app commands don't work on Wi-Fi devices

`device info apps` / `process launch` die after 30 seconds with
`AMDeviceCreateWithRemoteDeviceUUID ... Failed to allocate RSD device`: the host side tries to grab
the device through MobileDevice and fails. So we connect directly.
- **Launch**: `launchapplication` on `appservice`. `platformSpecificOptions` is required in the
  input, and its value must be a **binary plist** (even if it's an empty dictionary). The key is
  `standardIOUsesPseudoterminals` (not …Devices). The `NSCodingPath` in the error message tells you
  exactly which field is wrong.
- **Listing**: we don't use `listapps` on `appservice`. With an empty result it answers right away,
  but **if even one app matches, the action never finishes on the device** (the device log shows
  "Invoking action" and never "Received reply"). Still true on iOS 27.3, which also wants
  `includeAppGroupIdentifiers`, `includeContainerPaths` and `requireContainerAccess` in the input.
  Instead we call the old lockdown `installation_proxy` (`Browse`, several messages until
  `Status: Complete`).
- **Update (Xcode 27, iOS 27.3):** since service sockets come from CoreDeviceService (#44),
  `.shim.remote` services can't be opened over Wi-Fi at all: `createservicesocket` fails with
  `CoreDeviceError 4000` over POSIX `EDEVERR`, although the device advertises the shim (`remotectl
  show`). `remotectl netcat` can't reach them either. So `apps` and `launch <name>` failed on every
  Wi-Fi device. Meanwhile `devicectl device info apps` started working over Wi-Fi (about 1.2 s), so
  it's the fallback (`InstallationProxy.browseDeviceCtl`). Its names are the apps' bundle names
  ("Settings" on a Korean device), not the localized display names installation_proxy gives
  ("설정"), and without `--include-all-apps` it lists only developer-built apps. `defaultApp` marks
  Apple's apps. The shim error mentions "connection", so it's caught; passed on, the daemon would
  drop its session for nothing.
- **Recovery**: once this daemon (`dtappserviced`) gets stuck, it accepts every later call and never
  answers. It still replies instantly to input-decoding errors, so it looks alive; don't be fooled.
  If a launch times out, find its pid via Instruments `deviceinfo.runningProcesses`, kill it with
  `processcontrol.killPid:`, and try once more. launchd restarts it on demand.

### 21. To open a bare URL, send it to SpringBoard

`launchapplication` needs a bundle ID; an empty string is rejected with "The application failed to
launch." Sending `payloadURL` to `com.apple.springboard` makes LaunchServices route it to the app
that handles it (`prefs:`, `https:`, custom app schemes, all of them). `payloadURL` has the Codable
shape of Swift `URL`, `{"relative": "<url>"}`; passing a plain string gives "dictionary required
here". Instruments `processcontrol` can also launch apps, but its only options are
`StartSuspendedKey`/`KillExisting`/`ActivateSuspended`, so it can't carry a URL.

### 22. Settings features have separate get/set actions under one feature

Device Hub's settings panel uses features like `customizeappearancesettings` on
`com.apple.coredevice.configuration`, but the actual operation is picked by the envelope's
`CoreDevice.actionIdentifier` (`com.apple.coredevice.action.setreducemotion` and so on). Without an
action you get a get, and **unknown input keys are silently ignored**, so if a set "succeeds" and
nothing changes, suspect the action first. Action names are in the host binary too
(`grep -oE 'com\.apple\.coredevice\.action\.[A-Za-z0-9.]+'`). This service drops the connection
after replying, so every call opens a new one.

Liquid Glass opacity is a Float on the device side, so a Double like 0.8 is rejected with "value
doesn't fit in Float"; we truncate to Float before sending. Location simulation is
`setsimulatedlocation` / `clearsimulatedlocation` under `simulatelocation` on `locationservice`.

### 23. Touch coordinates follow the panel's native orientation

On the iPad, `getdisplayinfo` reports `bounds` and the screenshot as landscape 2420×1668, but
`nativeOrientation` is `rot270`. Sending the screenshot-relative coordinate (u, v) as-is taps the
wrong place; rotating it to (1−v, u) is correct (verified on the Settings icon). The iPhone is
`rot0`, so it passes through unchanged. The formulas for the other orientations follow the same
rule but have not been checked on real hardware. We also haven't seen how the screenshot and
`bounds` come back when the iPad is rotated to portrait.

### 24. Swipes keep momentum even if you hold still before lifting

Even after holding the end point for 0.2 s before lifting, a scroll dragged at constant speed for
0.5 s travelled 1.8× the drag distance: the device doesn't treat stationary reports as motion and
flings with the last real movement speed. `scroll` eases out toward the end so the final speed is
near zero. The content then moves by the drag distance minus the touch slop (around 50 px).

### 25. Capture succeeds even when the screen is off

The device returns a black image with no error, and an agent reading it goes looking for elements
that aren't there. A nearly black capture is an error in `wait` and a warning in `screenshot`/`--shot`.

There is no good way to detect the lock state. The `getlockstate` feature is rejected by the device
as "not implemented", and accessibility's `deviceRunningApplications` returned an empty array
whether locked or not. MobileDevice's `AMDeviceValidatePairing` failing with 0xE8000025 is not a
lock signal either: the iPad failed with the same code while unlocked (looks like a lockdown pairing
record problem). So lockdown services fall back to the tunnel path when USB lockdown fails.

### 26. Without a device selector, commands went to whichever device remotepairingd listed first

That list also contains devices that were paired once but aren't connected now, so with two devices
it was luck which one got controlled. `DeviceResolver` looks only at currently reachable devices
(`currentDevicesOnly`), and if there isn't exactly one, it stops and lists the candidates.

### 27. RSD handshakes right after a new tunnel get dropped

After a period with no commands, the next run gets a fresh tunnel (the tunnel IP changes every
time). If we connect with the same UUID before `remoted` has finished its handshake with the device's
RSD, the device drops us immediately and `send` fails with Broken pipe. Every command just said
"connection lost", and running them back to back, the second one onward worked. Both USB and Wi-Fi
did this. So the RSD connection retries for up to 8 s, rediscovering the port each time (usually
1–2 s). After "connection lost", the parentheses say whether the peer closed, sent GOAWAY, or hit a
socket error.

No longer applies: that RSD connection itself displaced `remoted` and cut Xcode off (#44). Sockets
now come from CoreDeviceService.

### 28. The daemon runs the code it was started with

After `swift build`, commands still went to the already running daemon and showed the old behavior,
and new options didn't even appear in `--help`. Requests now carry the client binary's path and
modification time (`BuildStamp`); if they differ from the daemon's own, the daemon refuses and exits,
and that command runs without the daemon.

### 29. App display names contain non-breaking spaces

"App Store" is actually `App Store`, so `contains("app store")` didn't match. Name comparison
now strips all kinds of whitespace.

### 30. Every clipboard paste shows a permission prompt

Content pushed through `pasteboardservice` appears on the device as coming from `dtpasteboardd`, so
even a ⌘V paste (user input) triggers the prompt ""Settings" would like to paste from
"dtpasteboardd"". An agent must not allow that prompt on the
user's behalf, so without a person present, assume paste is blocked and use `text` first. If the user
sets the app's "Paste from Other Apps" setting to Allow, the prompt stops appearing.

### 31. With the keyboard up, a swipe in the middle of the screen types

`scroll` once dragged from the center of the screen, the start point landed on the G key of the iPad
keyboard, and "G" was typed into the Settings search field. Now `scroll` first detects the keyboard
by OCR (four or more side-by-side rows of single characters) and drags only above it.

### 32. Keys typed without a focused field become app shortcuts

A subagent in the Music app tapped only the Search tab, not the input field, and ran
`text "<an artist name>"`. Our HID keyboard looks like a physical keyboard to the device, so with no
field focused the keys go to the app's keyboard commands: the space started playback and the letters
jumped to an unrelated category screen. So `text` first checks by OCR whether the on-screen keyboard
is showing (`TextRecognizer.keyboardVisible`, about 0.5 s) and fails without typing if it isn't. The
on-screen keyboard still appears when a field gets focus even though our virtual keyboard is attached
(apparently because it is the "software keyboard" service from #11). For a device where a real
physical keyboard hides the on-screen keyboard, use `--force`.

### 33. A scroll that starts low on the screen is caught by the bottom bar

`scroll` dragged around the screen center, so `--amount 0.7` started at 85% of the screen height. In
iPhone Safari that is the address bar, and the upward drag opened the tab overview. The drag is now
confined to 10–80% of the screen height (above the keyboard if it's up). That caps one drag at 0.63;
asking for more is reduced, with a notice.

### 34. A constantly moving screen never settles

An artist page in the Music app has a header video that loops forever (about a quarter of the
screen). With only "two identical frames in a row means settled", `--shot` waited the full 6 s every
time and appended "still moving", and `wait --stable` failed with a timeout so the agent called
`screenshot` again. Now, if three consecutive changes are confined to one rectangle within a third of
the screen, the screen counts as settled and that rectangle is reported. `wait --stable` saves the
last frame to `-o` even on timeout.

### 42. A row can move between measuring and tapping

Written for the accessibility path (`AXWalker` and the preview and focus boxes, archived as #36–37).
What today's code keeps is the comparison in the second bullet: `ScreenCapture.sameArea`, which `press`
runs on every line before tapping (#48).

In a messenger app's chat list (iOS 27.2), `press` on a pinned chat opened the chat three rows above
it. Measured again later, the rect was right every time, so the list most likely moved after measuring
(not reproduced). Two things move it: an ad banner at the top loads and resizes, and the pinned rows,
drawn at the top, come after the other rows in focus order, so walking to them scrolls the list back
and forth.

- The fast-path check in `AXWalker.measure` compares frames on the coarse 48x104 grid and only in a
  band around the element. A list scrolled by about 320 px (one and a half rows) still passed it, because
  neighboring chat rows look alike at that resolution.
- Now one more frame, taken with the boxes cleared, is compared with the measuring frame over the
  element and half a row above and below at 1/8 size (`ScreenCapture.sameArea`). The shifted list
  changed 17% of that area; up to 4% is allowed for a blinking cursor or a badge. It costs one capture
  (~0.6 s) per press.
- Measuring again right away without moving focus fell back to the yellow preview box, which failed on
  that row, and the old rect was used, which is the original bug. Now it waits for the screen to settle,
  steps away and back so the green box is drawn at the new position, and measures again. If the element
  is still moving after three tries, it stops with "kept moving" instead of tapping.

### 44. Our own RSD handshake cut Xcode off from the device

Building and running an app from Xcode or `xcodebuild` while iphone-use was in use hung at "Connecting
to <device>" and timed out after 60 s ("Timed out waiting for all destinations"). Stopping the daemon
didn't help; only replugging (once, rebooting) the device did.

`remoted`'s log showed why. Every iphone-use command, daemon or not, opened its own RSD connection
with `remoted`'s UUID (the old #27 setup). At that moment `remoted` logged `Device must renegotiate
TLS` and `Device connection interrupted` for the `coredevice-N` device, then retried forever with
`Heartbeat failed: not connected`. CoreDevice still reported the tunnel as connected, but Xcode's device
preparation never finished. With a random UUID `remoted` did reconnect within milliseconds, but the
device then closed the listeners we had just been told about (Connection refused). The device keeps
one RSD peer per tunnel, so a second peer always displaces someone.

Dead ends: `remote_service_create_connected_socket` from RemoteServiceDiscovery.framework, and
`remotectl netcat`, are both refused by `remoted` ("Client lacks privilege") for `coredevice-device`
services. `remotectl reset` doesn't revive the stuck connection.

What works is what devicectl does: check in with `CoreDeviceService` over XPC, take a usage assertion
(`acquireusageassertion`), then ask for a socket per service (`createservicesocket`). The descriptor
arrives in the reply, already connected through `remoted`. `CoreDeviceClient` does this, and the RSD
code (tunnel assertion, `nettop` port lookup, handshake) is gone. Details found along the way:

- The assertion action's reply only arrives when the assertion ends. That it took hold is a
  `CoreDevice.AssertionFulfilledMessage` sent to the listener passed as `endpoint`.
- The socket arrives non-blocking; reads fail at once with EAGAIN unless that is cleared.
- Lockdown shims (`*.shim.remote`) didn't come through it over USB ("A connection to this device could not be
  established", or no reply). Over USB, accessibility and `installation_proxy` are started with
  MobileDevice instead, which leaves `remoted` alone. The service connection outlives the lockdown
  session, but invalidating it silences the DTX session, so it is held until the socket closes.

### 46. A notification banner over the top of the screen takes the tap

A banner covers roughly 6–15% from the top of an iPhone for about five seconds. `press` on a toolbar
button while one was down opened the notification's app. The banner is not in the accessibility walk
(`ui` during a banner listed only the app), and the hit test returns nothing (#35, archived).

`press`'s moved-since-measuring check (#42) doesn't catch it: the banner is in both frames.

A guard was prototyped and worked on a device. Before input in the top 22%, it compared a full-width
strip around the point with the last frame the agent looked at, ignoring the status bar. When only the
top had changed and the rest of the screen had not, it waited up to 8 s for the banner to leave and
refused if it stayed.

The reference must come from a look (`screenshot`, the list after `ui`), never from measuring. A
banner already down then becomes the reference, and the guard passes it. The reference must also be
dropped after each input, or a control that changes only the top band looks like a banner.

It was not merged. It costs a box-free capture on every `ui` and `press`, adds a state file, and can
wait and then fail on screens whose top changes on its own. Instead, SKILL.md suggests Do Not Disturb.
It also treats `New screen — <another app>` after a press near the top as a banner tap: don't act
there, `launch` back.

### 48. OCR lists every line it read; the caller never guesses a string

The first OCR commands (`find`, `tap "text"`) took a string from the caller and tapped the line that
matched. They often pressed the wrong place: the guess matched several lines (a title and a row with
the same word), or OCR had misread the line the caller meant. That is why the accessibility list
replaced them. The accessibility path was then dropped for speed: walking focus to an element and
measuring the green box (#37, archived) took 5–8 s per `press` and 2–3 s per list, and only the focus order
was listed, not what the screen showed.

What the code does now:

- `ui` reads the whole screenshot (Vision, `accurate`, Korean and English, about 0.3–0.6 s) and prints
  **every** line with a ref and its grid cell, and saves the screenshot with the grid drawn on it. The
  caller picks a line it has seen, or reads the image for icons and toggles, which have no text.
  With the daemon running a `ui` takes about 1 s.
- Lines are sorted into rows by vertical center (Vision returns them roughly by column, which put a
  row's value after everything on the left).
- Status items (clock, battery, carrier, signal dots) can't be cut by position. Since the foldable
  iPhone they sit differently per device: a strip along the top on most iPhones and iPads, a floating
  pill at the right edge on the foldable, where its "9:22" and "80+" (the charging bolt read as "+"
  or "4") came out as list lines in the middle of the screen. So the clock is found by its value:
  a line in the top 30% showing this Mac's time (±1 minute, 12- or 24-hour) is the clock, and short
  digit-like lines within four clock heights of it go too. Without a clock, only short digit-like
  lines in the top 5% go; cutting the top by height alone also cut the navigation bar title on an
  iPad, where it sits almost as high as the status bar.
- `ScreenCapture.signature` still skips the top 6% for settling. On the foldable the clock pill is
  below that, so a minute tick can cost one extra capture before the screen counts as settled.
- Keyboard keys are dropped from the top key row down (`TextRecognizer.keysTop`), without the 14%
  allowance `keyboardTop` adds for scrolling: that allowance swallowed the chat input field just
  above the keys.
- Each line keeps a small grayscale crop of where it was read. `press` taps only if that area still
  looks the same (`ScreenCapture.sameArea`, #42); otherwise it reads the screen again and taps the
  line with the same text only if there is exactly one.
- After an action the new lines are matched to the old ones (same text nearby, same text anywhere,
  then different text in the same spot as `changed`). If fewer than half match, it's a new screen
  and refs restart at 1.

### 49. A video player's controls come late and leave on their own

Tapping a playing video in a media player shows its controls about 0.8 s later (fading in; the tap
waits out a possible double tap), and they hide again about 3 s after that. The action report waited
for the screen to settle, and over a playing video that ends either by timeout or by the "only one area
keeps moving" rule (`ScreenCapture.settled`), somewhere between 1.5 and 6 s. In five tries the report
saw the controls in about half; `touch --no-ui` followed at once by `ui` saw them in one (too early).
`touch --no-ui`, one second's pause, then `ui` saw them five times out of five.

Reading the earliest frame that differed most from the settled one, to list text that "showed briefly",
was tried first and dropped: frames come about 0.35 s apart, so the pick often caught the controls
halfway through fading (one or two labels readable), and OCR missing a small label in one frame looked
like the label vanishing.

What the code does now: when the settle reports a moving area or never settles, the report reads the
frame captured about 1.2 s after the input (`UIScreen.observeAfterAction`, `Settle.early`) and says so.
Over a screen that settles normally nothing changes. Five tries out of five listed the controls.

### 50. A long-held HID connection stopped delivering input while still answering PINGs

The daemon used to open `universalhidservice` and `hid.indigo` once and keep them for its whole life,
syncing each command with a PING (#16). On an iPhone over Wi-Fi (iOS 27.3), after the daemon had
served many commands (back-to-back screenshots, `ui`, `touch`, `press`), `touch` kept printing
`Tapped …` while nothing happened on screen, for over a minute of retries. The PING still got its
ACK, so nothing looked wrong. The same command with `--no-daemon` worked at once, and a fresh daemon
worked too.

We could not reproduce it on demand. Ruled out, measured on the same iPhone:

- **HTTP/2 flow control.** The device advertises a 1 MiB initial window and does send WINDOW_UPDATE
  (connection and stream) once about half of it is used. After 1.1 MB of reports on one connection,
  a tap still landed.
- **Locking and unlocking the screen** with a daemon connection open: the next tap landed.
- **A `--no-daemon` HID client running alongside** the daemon (checked when the bug was found).

What we know points at per-connection state on the device: `dtuhidd` creates the virtual touchscreen
and keyboard surfaces for each `universalhidservice` connection and deletes them when it closes (#11).
If that surface goes away or stops being routed while the connection stays up, reports are read
(so the PING is answered) and dropped. A new connection gets new surfaces.

So the daemon now opens HID per command and closes it after the PING, exactly like a plain CLI run;
only the tunnel and screen size stay cached. That made a daemon `touch` about 0.12 s instead of
0.06 s. The `hid.indigo` connection was the expensive one (opening both took 0.25–1.1 s over Wi-Fi),
so it is opened only when a button is pressed. Repeated `button home` still does not merge into a
double press with the per-command close (#17's 0.8 s wait covers it).

If it shows up again, the next step is the device syslog filtered to `dtuhidd` while a tap fails.

### 51. The foldable iPhone has two panels, and everything defaulted to the cover one

The foldable iPhone (iOS 27.3) reports two panels in `getdisplayinfo`: `LCD`, the cover panel
(1398×2034), and `LCD-1`, the inner one (2007×2853). `LCD` is always listed first, even while the
phone is unfolded, the cover is off and `LCD-1` is the one with `active: true`. Three things followed
the first panel:

- **Screen size.** `ScreenSize.query` took the first display with a size, so coordinates were scaled
  for the cover panel.
- **Screenshots.** `capturescreenshot` without input captures the first panel, which is black while
  unfolded. It takes a `displayUniqueID` input (the panel's `uniqueId` from `getdisplayinfo`; the
  host binary's `CaptureScreenshotInput` names it), and an unknown ID fails with "The requested
  display could not be found".
- **Touches.** Each panel has its own HID touchscreen: `hid-info` lists surface 257 with the cover
  panel's `displayUUID` and 258 with the inner one's. Reports sent to 257 while unfolded vanish
  without an error. We number surfaces from 257 in the panels' `getdisplayinfo` order instead of
  reading the surface list, because asking for that list stalls HID input for minutes (#15). That
  order is only observed on this one device.

The inner panel also turns with the UI, unlike the iPhone's single panel so far: held sideways it
reports `currentOrientation: rot90` while `bounds` stays 2007×2853, and the screenshot comes back
2853×2007. Touch coordinates stay in the panel's native portrait frame, so a point (u, v) on that
screenshot is sent as (v, 1−u), the same `rot90` formula as #23 (verified by tapping the Music icon
in the Dock on the sideways home screen). So the rotation is `nativeOrientation` plus
`currentOrientation`, and `currentOrientation` of rot90 or rot270 swaps width and height. On the
iPad the earlier #23 check matches this if its `currentOrientation` was rot0 then; we haven't checked
an iPad held in another orientation. `rot180` (held upside down: portrait screenshot, `currentOrientation:
rot180`) hasn't been tapped on hardware.

`bounds` (2007×2853) also differs from `nativeSize` and `frame` (1878×2670) on the inner panel. The
screenshot matches `bounds`, and touches are normalized, so only the ratio matters.

What the code does now:

- `ScreenSize.query` picks the `active` panel (the first with a size if none is, as when the screen
  is off) and carries its `uniqueId` and touch surface.
- Screenshots pass that `displayUniqueID`. `settled` looks the panel up once per wait, not per frame.
- `InputSession.open` points `HIDService.touchSurface` at the panel's surface.
- The daemon no longer caches the screen size: folding or turning the phone changes it, and the
  lookup costs about 50 ms over the daemon's held connection (30 ms to connect, 20 ms for the call).

### 52. Switches and icons are found by shape, not by a model

OCR gives no line for a switch, a check mark drawn as a glyph, or an icon-only button, so an agent had
to open the screenshot to tell whether a switch was on or to find a back chevron. `ScreenElements` now
finds them on the Mac in about 15 ms and lists them as `[bracketed]` lines among the text.

What was tried, on 14 screenshots of the foldable iPhone (Settings, a dark-mode Clock, App Store,
Reminders, and two social apps with their own icon art):

- **Vision contour detection** (`VNDetectContoursRequest`) found none of the light-mode off switches:
  a light gray track on a white card has too little contrast. Dropped.
- **Flat-color regions.** The screen, scaled down to points, is flood-filled into regions of about one
  color; regions over 1,500 pt² are backgrounds, and the rest groups into blobs. A switch is a blob
  22–40 pt high, 1.7–2.8 times as wide, filling over 60% of its box, with a near-white knob. Its state
  is the knob's side, not the track color: apps tint the track, and an off track is light gray in
  light mode but dark gray in dark mode. 14 of 14 switches right, no false ones.
  - Matching the track region alone (without grouping) missed most on-switches: the iOS 26 knob is a
    wide pill, so the green left of it is nearly square.
- **SF Symbol templates.** Small one-color blobs are compared with about 50 common symbols, rendered in
  three weights (a list's check mark is light, a back chevron semibold). Right for every named one in
  Apple's apps (back chevron, row chevrons, ⓘ, check mark, Clock's tab icons, share, plus).
  - With all ~9,500 symbols, look-alikes won as often as the right one (App Store's Games tab came
    out as `octagon.fill` at 0.92), and rendering them took 20 s. The short list is kept.
  - Filled discs (`xmark.circle.fill`, `checkmark.circle.fill`) matched round profile pictures at up
    to 0.98, so they're not in the list.
  - Below 0.94 a name is more often wrong than right; those stay `[icon]`.
  - Apps with their own icon art (the social apps) get only `[icon]` and a position.
- **"One color".** Icons are a single color; photos, avatars and emoji aren't. Measuring the color
  spread over all differing pixels failed every glyph, because anti-aliased edges are blends with the
  background. Only the solid core (pixels at least 80% as far from the background as the farthest)
  is measured, and a photo is caught by how few of its pixels are core.
- **The on-device model** (macOS 27 `FoundationModels`, which takes images). Given a whole screen it
  named switch states correctly but skipped half of them, garbled Korean labels, gave no positions,
  took 1.6–5 s, and on one screen repeated the same item fifteen times. Given one icon cut out, it
  named app-specific icons well (house, paper plane, play button, rocket) in about 0.55 s each. A
  candidate for naming `[icon]`s on request, not for every `ui`.
- Big icons right before a row's text (Settings' colored squares, profile pictures) are left out:
  pressing the text does the same, and they doubled the list.

Pixels per point come from `getdisplayinfo`'s `pointScale`, asked once per screen size. The screen
size alone can't tell: the foldable's inner panel (2007 px wide, 3x) is as wide as an iPad (2x).

Known gaps: icons on a Liquid Glass bar floating over a photo or video (the background isn't flat, so
there's no region to subtract), and glass buttons whose shadow blends into what's behind.

### 53. Ten grid cells across was right only on an iPhone

The grid divided the screen's short side into ten cells: about 40 pt on an iPhone, but 47 pt on the
foldable's cover panel, 67 pt on its inner panel and 83 pt on an iPad. `touch --cell` taps a cell's
center, which can then be up to half a cell from the control the agent meant. Measured on 282 targets
(controls and short text) from 14 screenshots of the cover panel, the center of the target's cell was
inside a 44 pt touch area around it 61% of the time with 58 pt cells, 90% with 47 pt, and 100% with
39 pt or smaller.

Cells are now about 40 pt everywhere: the cell count comes from the panel's `pointScale` (#52), with
ten as the minimum. `--grid-size` still overrides it, and `screenshot --grid` prints it in its tap hint
only when it was given. The saved image stays 720 px wide, so an iPad's cells are smaller on it
(about 34 px, labels still readable).

### 54. A new HID connection drops the reports it gets while the device is busy

After #50 the daemon opens `universalhidservice` per command, like a plain CLI run. Taps still went
missing now and then: `press` printed `Pressed …`, the screen didn't change, and pressing again
worked. With the device idle it never failed (about 300 taps through the daemon, folded and unfolded,
fresh daemon, right after `open`, after 12 s of idle). With the device busy it failed often: with
three `screenshot --no-daemon` loops running alongside, taps on the Clock tab bar were lost, through
the daemon and with `--no-daemon` alike.

How often swings a lot over time: the same setup lost 15 of 15 in one run and 0 of 15 half an hour
later. So variants are only compared **interleaved tap by tap**, never run after run. Under load,
summed over five interleaved runs:

| first report after the connection opened | lost |
|---|---|
| at once (the old behavior) | 34/85 |
| 0.06 s, 0.1 s | 30/30 |
| 0.15 s | 0/35 |
| 0.2 s, 0.3 s | 0/30 |
| 0.25 s | 8/20 (one run) |
| 0.4 s | 1/55 |
| 0.6 s | 0/20 |
| at once, 0.2 s hold instead of 0.08 s | 1/50 |

Without load every variant lost 0 of 20. A tap needs about 0.05 s of contact on the device at all
(idle: a 0.02 s hold lost 6/6, 0.04 s 2/6, 0.08 s none).

So it is time since the connection opened. `dtuhidd` creates a touchscreen and keyboard surface for
each connection (#11); reports that arrive before a busy device has them in place are dropped, and
the PING that ends the command (#16) is still answered.

What didn't explain or fix it:

- **Wi-Fi delivery.** The PING round trip does jump to 100–600 ms after half a second of idle (the
  device's power saving), but the PING after a tap's release came back in 11–25 ms every time: the
  reports weren't held up in flight.
- **A PING before the first report.** One PING after connecting: 28 of 30 lost under load. PINGing
  every 50 ms through the wait was worse than a plain sleep, even without load (9 of 30 lost). The
  HTTP/2 layer answering says nothing about the surfaces, and the PINGs seem to get in the way.

What the code does: `HIDService` sleeps until its connection is `surfaceSettle` (0.4 s) old before the
first report, and `InputSession.open` connects HID before asking for the screen size, so that lookup
uses up part of the wait. The hold stays 0.08 s, so a tap is still a short tap to apps. Every touch
and key command costs up to 0.4 s more; only the first report waits, so a long `text` pays it once.
Buttons go through `hid.indigo` and don't wait.

The losses that led here were on the foldable's cover panel, right after a fresh daemon or an `open`:
moments when the device was busy.

### 55. A device without its Developer Disk Image refuses every service socket

After a reboot an iPad on Wi-Fi showed up as `connected (no DDI)` in `xcrun devicectl list devices`,
and every command failed with "The capability “Create Service Socket” is not supported by this
device". Pairing, the tunnel and the device itself were fine; the screenshot and HID services live on
the Developer Disk Image, which Xcode mounts the first time it touches the device. Until then
CoreDevice reports the socket action as unsupported rather than missing.

Any `devicectl` query that needs the DDI mounts it as a side effect (`device info processes` did, in
a few seconds). What the code does: when `createservicesocket` fails with "not supported",
`CoreDeviceClient.serviceSocket` runs `devicectl device info ddiServices` once and retries; if it
still fails, the error says to mount the DDI and contains "connection" so the daemon drops its
session (`DaemonCommand.swift`).

### 56. An iPad's status clock carries the date, and its VPN badge reads as "{} VPN"

The status filter (#48) finds the clock by matching the Mac's time exactly ("3:00"). An iPad's status
bar shows "3:00 PM Sun Nov 8" (localized), which OCR returns as one line, so it stayed in the list as
the first line; the VPN badge at the far right, nowhere near the clock, came out as "{} VPN" or
"() VPN" and stayed too. The filter now also takes a short line in the top 5% of the screen with the
current time as one of its words, and treats a short line whose letters are "VPN" as a status item
(still only at the very top or next to the clock, so a Settings row named VPN stays). With the Wi-Fi
glyph and battery beside it the badge read as "{} VPN ⑦ 80)", so the VPN rule allows up to 16
characters.

Dropping the whole clock line took the "◀ Settings" breadcrumb with it: when another app opened this
one, the iPad puts the way back in front of the clock, and OCR reads "◀ Settings 3:22 PM Sun Nov 8" as
one line. A clock line starting with ◀ or < keeps the words before the clock (and before its AM/PM
marker), with a frame cut by their share of the characters.

### 57. The on-device model names a cropped icon well and a whole screen badly

`ui --icons` asks the Mac's FoundationModels model (macOS 27 accepts image attachments) about each
`[icon]` the SF Symbol templates (#52) didn't match.

- **A whole screenshot with "list the controls":** a few seconds, controls that weren't there, most
  icons missed, switch states guessed. Not usable.
- **A crop of one icon, "what does this depict?":** about 0.5 s, and names an agent can act on
  ("paper plane", "download", "heart"). The crop is a square of 1.6× the icon, at least 40 pt: a tight
  crop of a thin glyph came back as "line".
- **One session for all icons:** the answers drifted toward the earlier ones. Each icon gets a fresh
  `LanguageModelSession`.

Names are kept across reads: an `[icon]` that a fresh read finds where a named one was, with the same
pixels around it (`ScreenCapture.sameArea`), takes the old name, so a plain `ui` after `ui --icons`
doesn't report every icon as changed. Without the pixel check, a carousel that slid a new picture into
the same place inherited the old picture's name.

Shape detection also picks out pieces of illustrations (a banner's characters); the model then names
them for what they are ("cat face"), which at least tells the agent they're artwork. Naming stops at
16 icons per run (`IconNamer.limit`); a second run names the next ones.

The code is compiled only with Swift 6.4 or later (the macOS 27 SDK, where image attachments exist),
and FoundationModels is weak-linked, so a build from an older Xcode, or a run on an older macOS, prints
why `--icons` can't name anything and keeps `[icon]`.

### 58. Hangul composes only while the on-screen keyboard is Korean

#11 holds: the HID layout is fixed per device. But on an iPhone whose layout is Dubeolsik, the
**on-screen** keyboard's language still decides whether the keys compose. With it on English, `type`
of "언제와" left the loose jamo `ㅇㅓㄴㅈㅔㅇㅗㅏ` in a chat's input field, and the next step would have
been the send button. With it on Korean, the same keys composed correctly.

`type` and `text` now read the keyboard's language off its key labels (`KeyboardLanguage.detect`:
single jamo vs single Latin letters below the top key row). For text with Hangul on a Latin keyboard
they press `ctrl+space` until the keys turn to jamo (at most 4 tries), type, and press it again until
they're Latin, **before** Return: a Return that sends or searches can take the keyboard away, and then
it can't be switched back. With several Latin keyboards, the switch back stops at the first one.
When it can't tell (the number or emoji pad), it types as is.

**It also depends on the app.** On the same iPhone, minutes apart, the same Dubeolsik keys composed
"배터리" in a chat app's search field but came out as `qoxjfl` in Settings' search, with the Korean
keyboard showing in both. So "the layout is fixed per device" (#11) is per field at least; nothing we
send changes it, and typing again gives the same letters.

`type` therefore reads the screen afterwards (every line, not just the changes: a search field that
fills in turns the screen into results, which reads as a new screen). Three loose jamo in a row, or the
Dubeolsik keys as Latin letters, print a warning not to send it and to use a deep link, a URL or
`paste` instead. OCR misreads the last letter often enough (`qoxjf°`) that five or more keys match with
one missing; shorter ones must match whole, because every line on the screen is checked.

`ctrl+space` also shows an input-source picker over the keyboard for about a second and a half. The
keys switch at once and typing goes to the field, so `type` doesn't wait for the picker to fade.

OCR drops the space between Hangul words ("가 나" reads as "가나"). The space is typed; look at the
screenshot before retyping.

### 59. A round button with a glyph on it was missing from the list

A chat's send button (a black arrow on a yellow disc, about 33 pt on the iPhone) never got a line, so
the agent tapped a grid cell for it; the cell's center fell just off the disc and nothing happened.
Two causes in `ScreenElements`' blob path:

- A disc under 44 pt is a single blob of two colors (fill and glyph), and the one-color check (#52)
  throws it out.
- A disc touching a larger shape (the input bar it sits in) joins that shape's blob, which is too big to
  look into. Two captures of the same screen differed in this: the colors after conversion moved a few
  edge pixels between regions.

`discButtons` works on the flat-color regions instead: a region 16–64 pt across, as wide as high,
covering 0.5–0.86 of its box, with points at 0.1 from each corner outside it (a rounded square, like a
Settings icon or an app icon, fills those) and points just inside each edge in it, and a glyph inside.
Fill is judged by color (within 24 per channel), not region id, because a slight gradient splits one
fill into several regions. The disc is the listed frame; the glyph is what the one-color check and the
symbol matcher look at. Blob pieces inside a disc are dropped, so it isn't listed twice. Settings,
General, Calculator and the home screen list the same controls as before.

`touch --cell` also snaps now: when the cell overlaps exactly one bracketed control (at least 20% of
it) without its center being on any control, it taps that control's center and says so. `--exact`
taps the cell's center.

### 60. Buttons by shape, and boxes on the screenshot

`ui --boxes` outlines each listed line on the saved screenshot with its ref, in blue over the magenta
grid, so an agent can match lines to the picture without reading cell names. The grid stays: what
detection misses still has a cell.

#59's disc search became `buttonShapes`: filled discs, capsules and rounded rectangles 20–96 pt high (#61),
from the flat-color regions. Kept out on purpose:

- **Square corners** (list rows, cards, banners): 2 pt in from each corner of a button's box is outside
  its fill when the corner radius is over 7 pt; on a row it's inside.
- **Wider than 70% of the screen**: a grouped list's one-row card or a search bar would box half the
  screen, and its text is a line already.
- **A rounded square with a glyph**: Settings' row icons and app icons. Only discs, and shapes at least
  1.4 times wider than high, take a glyph.
- **More than one text line, or text over the edge**: chat bubbles and cards. A short one-line bubble
  still passes (a "Skt" reply on a yellow bubble was boxed); it only gets an outline, no line.

A shape with one text line on it adds no line: the text is pressable already, and the shape is kept as
that line's `button` so `--boxes` outlines the whole button. A shape with a glyph is listed as
`[circle button]` / `[button]`, or by the glyph's symbol name. The glyph pieces inside are dropped from
the icon pass, so nothing is listed twice.

The fill tolerance follows the contrast with the surroundings (half of it, at most 24). With a fixed 24,
light gray chips on white (about 15 apart) took the page for their fill, their corners looked filled,
and only the dark selected chip was found.

Checked on a messenger app's chat list, chat and friends tab, Settings, Calculator and the home screen: chips,
round input buttons and the profile disc are found; rows, widgets and app icons aren't. The full read
(OCR included) takes 0.6–1.0 s per screen in a release build.

### 61. The Calculator's keypad passed for an on-screen keyboard

`keysTop` took any row of four or more single-character lines in the lower part of the screen as the
keyboard's top row. The Calculator's keypad (five round keys a row, single digits on them) matched, so
`ui` dropped every key from the list and said "the on-screen keyboard is up; its keys are left out".
A source-blind agent had to tap all of it by grid cell. Now a row needs six: a real keyboard's top row
has ten keys, and OCR misses a few thin ones (`I`, `l`). The note is printed only when keys were
actually left out; the looser `keyboardVisible`, which also fires on keypads, still guards `type`.

With the keys back in the list, the gray glass keys left `[icon]` fragments along their rims. Two
changes made each key one button (`buttonShapes`, #60):
- Shapes up to 96 pt high (the keys are about 76 pt on the foldable's inner screen).
- The contrast with the surroundings is sampled 4 pt outside the shape, not 2: right outside a glass
  key is its own darker rim ring, which made the tolerance so tight that half the key wasn't fill.
A few keys (`1`, `6`, `AC`, `.`, `÷`) are still missed; they're text lines or cells.

`touch --cell` snapping (#59) now needs a near miss: the cell's center within a quarter cell of the
control. On the Calculator, a cell whose center sat on an unlisted key reached into a listed neighbor,
and snapping would have pressed the neighbor. The message names the control's own cell so the agent can
see where the tap went.

Measured with two source-blind runs of the same task (Clock's city list, 12 × 7 on the Calculator), one
with plain `ui` and one with `ui --boxes`, before these fixes: 16 commands and no misses with the grid,
32 commands and 4 misses with boxes. Three of the four misses were stale refs from pressing several
keys without reading the list in between; the boxes neither caused nor prevented them. Both runs spent
most of their commands on the keypad that wasn't listed.

### 62. Lone digits, gradient keys, tile glyphs, hopping refs and a dead cached tunnel

Found in one session on an iPhone 12 Pro Max (iOS 27.2):

- **The Calculator's digit keys came out as `[circle button]`.** Vision's screen-wide read skips a
  lone character. About half the single-digit keys had no line, a different half from frame to frame,
  and the display's `0` was an `[icon]`. Cropping a key and reading it alone wasn't enough: an isolated
  digit was often read upside down (`9` as "6") or not at all. What reads reliably is the glyph as the
  last letter of a word. Each unread glyph is turned dark on white and drawn right after a "Key" on its
  own row, and the rows are stacked in one image (`TextRecognizer.labels(forGlyphs:)`). Two language
  settings each drop a different glyph now and then, so both run (about 0.05 s each). Trusted results:
  anything with a digit, or two to four letters. A lone letter or punctuation is more often a misread
  glyph (`÷` read as ".", a clock face as "O"). A lone "O" counts as zero only on a narrow glyph.
  Unnamed `[icon]`s get the same read, digits only.
- **A small glyph matched a symbol**: the `.` key was `[alarm fill]`. A glyph under 0.2 of its button
  isn't given to the symbol matcher.
- **The `6` key was dropped as a leading icon.** It sits right before the minus key's label, and
  `leadingIcon` took that label for the 6's row label. Text on its own button is a key's label, so it
  no longer counts.
- **The `÷` key was missing.** The orange keys have a slight gradient. The region seeded at the top
  covered only part of the key, the sample 4 pt above it was the same orange, and the contrast came out
  as 3. When an outside sample is within 16 of the fill, the box first grows over that color
  (`RegionMap.grow`). The same growth rejoins a Settings icon that a gradient split into two halves.
- **Settings' row icons came out as stray characters** (`*` for Bluetooth, `©`, `®`, `(g))`, `이` for
  Wi-Fi). One-color rounded squares are now returned as tiles. An OCR line of up to four characters
  inside a tile, with a label right after the tile, is dropped.
- **A symbol's filled body listed as a button**: Clock's tab bar gave `[alarm fill]` and a
  `[circle button]` at the same spot. A generic button inside a named symbol is dropped.
- **Refs hopped between lines.** Lines were matched in line order, then "same text anywhere". A key
  whose digit OCR lost became `[circle button]` and took a neighbor key's ref. The `7` key's ref moved
  to the `7` that appeared in the display. Now the nearest same-text pairs go first, across the whole
  list. A farther match is accepted only along with the rest of the list. The shift is the median of
  lines whose text is distinctive and appears once on both sides, and at least two of those are
  needed.
- **The first `ui` through the daemon failed with `connection lost (… reset by peer)`.** The tunnel
  cached while idle was dead. The daemon dropped it, and the same command worked right after. The
  daemon now runs a read-only command (`ui`, `wait`, `screenshot`, `apps`, `devices`, `clipboard`,
  `hid-info`) once more on a fresh tunnel, if it failed with a connection error before printing
  anything. Input commands aren't retried: the input may have reached the device.
- **Safari's address bar reads the keys as Latin letters** even with the Korean keyboard showing, like
  Settings' search (#58). Notes' search composes Hangul. SKILL.md points web searches at a search
  URL.

Not fixed: the home screen's icon artwork (a clock face's numbers, the Maps arrow) still gives
`[icon]` lines, and the dock's apps have no label to list. SKILL.md already says to use `launch`.

### 63. Things found by running every command on one phone

Second pass on the same iPhone 12 Pro Max (iOS 27.2), going through Settings, Clock, Notes, Safari and
the appearance, location and paste commands:

- **A picker's selected row couldn't be told from the list.** OCR read Auto-Lock's check mark as "/",
  "~" or "v" depending on the row, and a chevron as "〉". An OCR line of one or two characters with no
  digit and no letter but v is given to the symbol matcher, and a match replaces the text
  (`ScreenElements.symbolNames`).
- **The status clock stayed in the list under another time zone.** Pinning the location to Cupertino
  moved the device's clock to Pacific time, so it no longer matched this Mac's. Any `H:MM` starting a
  short line in the top 3% now counts as the clock. After `location --clear` the device kept Pacific time until an
  app got a real fix again (opening Maps did it). The signal dots (`••••`) are dropped too.
- **The Calculator's history button went missing** whenever the device's clock matched this Mac's:
  controls within four clock-heights of the clock were dropped as status glyphs. Now only those on
  the clock's own row are.
- **`type` refused to type into an open note.** Notes' keyboard came out as merged lines ("QWERT",
  "YU 1", "ASD"), no line was a single character, and the keyboard wasn't found. A wide run of two to
  ten letters in one case counts as that many keys (`TextRecognizer.keyCount`).
- **"Hello" came out as "ㅗㄷㅣㅣㅐ" without a word from `type`.** With a Korean hardware layout the
  HID keys compose jamo wherever the app doesn't force Latin. `type` now looks for the typed word after
  typing and warns when the screen shows a run of jamo in its place (`KeyboardLanguage.latinAsJamo`).
- **A page indicator's dot was `[stopwatch fill]`.** An icon under 12 pt isn't given to the symbol
  matcher.
- **A weekday button was listed twice or as `[icon]`** (an alarm's repeat row). An icon group around a
  text line's center is that line's button and is skipped. An unnamed icon that reads as one Hangul
  syllable is listed as that syllable.
- **A Settings row's tile glyph merged into the label** ("이 Wi-Fi"). A first word of up to two
  characters that starts inside a tile is stripped when the line runs well past the tile.
- **A list row's swipe actions weren't listed, and pressing their captions did nothing.** They are
  glass capsules with the caption below. The glyph was measured inside the capsule's box, and the page
  showing in the box's round corners made the "glyph" as big as the button, so the shape was dropped.
  The glyph is now measured inside a capsule a little smaller than the shape. A short line right under
  a nameless button names it (`[button] Delete`), the way a switch takes its label.
- **`paste` left the prompt for the next `ui`.** It now prints the list like the other input commands,
  so the paste permission prompt shows up in its result (`--no-ui` to skip).
- **`press 스톱워치` said only "not a ref".** The error now names the refs in the last list whose text
  matches.
- **A row right above a floating bar ignores taps.** On Settings' first screen, taps up to about 18 pt
  above the glass search bar did nothing, while the same row answered a tap a little higher. The tap
  was sent where intended, so it's the device's hit testing. SKILL.md says to scroll the row up first.

Not fixed: the passcode screen captures as a black image, so the tool says the screen is off. The
brightness slider has no line. A picker wheel's selected value isn't marked.

### 64. Things found by driving a test app built for it, and two third-party apps

A SwiftUI app with one screen per kind of control (switches, pickers, buttons, fields, lists, sheets,
custom-drawn controls, gestures, a web form, a grid of icons) and a "Last: …" line that echoes every
action, then an encyclopedia app and a portal app from the App Store. What broke, and what the code
does now:

- **A date picker's month grid counted as a keyboard.** A week of single digits ("3 4 5 6 7 8 9") is
  seven "keys" in a row, so `ui` dropped everything from that row down, the tab bar included, and said
  the keyboard was up. A calendar always shows the days 10 to 28 and no keyboard has two-digit keys:
  with eight or more of those on screen, digits and weekday initials stop counting as keys
  (`TextRecognizer.keyLines`).
- **A week came out as one line** ("12 13 14"), so only the middle day could be pressed. A line that is
  nothing but numbers of one or two digits is split into one line per number, each with Vision's own
  box for it.
- **A tab bar's selected pill was `[toggle off]`.** It has a switch's size and shape and a few white
  pixels off-center. A switch's knob is now at least a quarter of it.
- **Latin words grew a Hangul syllable** ("Cherry옓", "Bordered헸") on blurred or translucent text, and
  each showed as a changed line. A trailing syllable outside KS X 1001 right after a Latin letter is
  dropped; real particles are all inside it. Common syllables still slip through ("Gestures쵸").
- **The same line read twice differed** in case ("Row 2" / "ROW 2") or in one letter ("subtitle of" /
  "subtitle ot"): removed-and-added pairs in every report, and `press` saying the line was gone.
  Lines now match ignoring case, and with one differing letter inside a word when the line has eight
  characters or more (`UIScreen.sameText`). A digit or a lone letter still counts as a change.
- **A tab bar's icon was ":" in one read, "⅛" in the next, `[icon]` in a third.** Punctuation as tall
  as an icon is listed as `[icon]`. The clock with the location arrow read into it ("11:30①") is still
  the status clock.
- **A password field can't be typed into by `type`.** While a secure field has focus, the keyboard is
  absent from screen captures, and so is the field's content afterwards: SwiftUI's `SecureField`
  stays blank, a web page's shows dots. `type --secure` skips the keyboard check and doesn't echo the
  text. Nothing in the capture says a field is secure, so the agent has to know.
- **What the HID keys type is per app, both ways** (#58 had one direction). On one iPhone: Dubeolsik
  in Notes, so "Hello" became loose jamo; Latin in the test app and in the portal app's search, so
  "홍길동" became `ghdrlfehd`. The on-screen keys always type what they show, so `OnScreenKeys.type`
  goes run by run:
  - digits, symbols and spaces by HID (same keys in both layouts);
  - the first run of letters by HID with the on-screen keyboard in that script, then one read of the
    screen. Letters that came out in the other script are deleted and that script is tapped from then
    on. Latin is probed with Latin keys showing because there a Dubeolsik layout leaves loose jamo,
    one per key, so the count to delete is exact; Hangul is probed with one syllable.
  - The probe looks only at lines that weren't there before, and for Hangul only at whether the keys
    show up as a Latin word: a search field kept "vks" while its suggestions listed "판", and OCR read
    "vks" as "uks" (one wrong letter in three or more is allowed).
  - The key positions are fitted to the labels OCR read (ten keys across the width, second row half a
    key in, third two keys in) and nothing is tapped unless six labels sit where that predicts, which
    rules out an iPad and landscape. There, typing is as before, with the warnings.
  - On the Latin keys Shift comes on by itself at the start of a sentence; the keys are read again at
    the start and after `.`, `!`, `?` or a newline, and their case says whether Shift is on.
  - Tapped Latin words go through autocorrection ("teh" became "the"). The output says to check.
- **Return after a keyboard switch did nothing.** `ctrl+space` brings up the input-source list for
  about two seconds, and it takes the Return. `type --enter` waits it out. The list also covers the
  middle of the screen, so an unclear probe is read again after it's gone.
- **A swipe action whose glyph OCR read as a character** ("타" for the trash can) wasn't named by its
  caption. It is now, and a caption that named a button is no longer listed on its own.
- **A menu's check mark was the first word of its row** ("V Free", "~ Apple"). It is split off and
  given to the symbol matcher; if that has no name for it (a web page's ticked box), it goes back.
- **A password's dots flipped between "•" and "."** on every read. A line of only dots is listed as
  that many "•".
- **Double tap.** Two commands are too far apart, so `press` and `touch` take `--double`.
- **More symbols** in the matcher (gear, lock, person, phone, envelope, pencil, flag, tag, cart, map,
  link, eye, …), and a glyph OCR read as "Q", "x" or "①" is given to it too.

Not fixed: text behind a glass bar comes out as noise that differs per read. A custom-drawn switch or
decorative disc can get a wrong symbol name (`[stopwatch fill]`). Which segment of a segmented control
is selected isn't marked. A status icon next to the clock can come out as a syllable. There is no
pinch. The system number pad's keys are listed (they aren't left out like the keyboard's).

### 65. Things found in three busy third-party apps

A shopping app, a food delivery app and a travel app from the App Store, used without signing in:
first-run prompts, a web login sheet, search, a product page, an address form, a custom calendar and a
flight search. Typing mixed Hangul and Latin text (#64) and pressing days in an app-drawn calendar
worked as they were. What broke, and what the code does now:

- **The status glyphs on the right came out as text** ("이4" in one read, "..이" in the next) whenever
  the Wi-Fi fan and the battery read as a syllable and a digit. A line of up to four characters on the
  clock's own row is a status item.
- **The way back to the previous app read differently every time**: "A App Store", "• App Store",
  "< App Store". It sits right under an iPhone's clock. A line there whose first word is one character
  is listed as `◀ App Store`.
- **A pager's dots were thirteen `[icon]` lines**, and a different number on the next read. Three or
  more small unnamed icons of one size, evenly spaced in a row, are one line: `[page dots] 13`
  (`UIScreen.pageDotsMerged`). Which dot is the current one isn't read.
- **A tab bar without captions listed its icons as letters**: a house as "A", a reload arrow as "C".
  A lone ASCII letter is `[icon]` when its row has two or more bracketed controls and no word. Digits
  stay as they are: a keypad key without a button shape sits among `[circle button]`s too, so a
  person icon read as "0" is still "0".
- **"^" and "=" as tall as an icon** (a back arrow, a menu icon) are `[icon]`, like the punctuation in
  #64.
- **The keyboard's suggestion bar was in the list** ("나", "아", "나는"), changing with every key. Two
  or three short lines at the thirds of the width, within 56 pt above the keys, are dropped with the
  keys. A lone line there stays, because a chat's input field sits in the same place.
- **`launch Name.com` failed (an app whose name has a dot) with "The application failed to launch".** Anything shaped like a dotted
  identifier was taken for a bundle ID. With exactly one dot, the installed apps are checked for that
  name first (`InstallationProxy.bundleId`).
- **A ticked box was "✓" on one row and "~" on the next.** Writing "~" as "✓" was tried and taken
  back: the same "~" is what OCR makes of an airplane icon before a city's name, and "✓ Seoul" claims
  a selection. Only "√" is rewritten.

Not fixed here (#66 later added lines for the popup, its close button, check boxes, the current page
dot and an icon in another color than its word):

- A close button on a translucent disc over a dimmed photo (a promotion popup's ✕) has no line, and
  nothing in the list says a popup is up. The lines behind it are listed with it; a scroll that
  changes nothing is the hint. Tap the ✕ by grid cell.
- An empty check box has no line. Its label is pressable and usually toggles it.
- An icon right before a word can join it as a syllable ("쓰파리", "뼈 11월 20일").
- A captioned icon that isn't a filled button (a sign-in provider's logo) is `[icon]` or a wrong
  symbol name, with its caption on a separate line below.
- A map inside a system location prompt is read as text (street names) among the prompt's lines.

### 66. State that isn't a control: check boxes, selection, sliders, pager position, popups

#65 left these without lines, so an agent had to open the screenshot for them. All are now read from
pixels on the Mac, checked on a test app with one screen per case and then against built-in and
third-party apps for false positives. A `ui` still takes 0.6–0.9 s.

- **Check boxes and radio buttons** (`RegionMap.checkBoxes`), listed as `[checkbox on|off] <label>`.
  - Empty: a blob 16–32 pt, as wide as high, that fills its box and has the page's own color at its
    center and a different one on its rim. The outline closes its inside off from the page, so ring
    and inside are one blob.
  - Ticked: the same size, filled with the rim's color, with a glyph in the middle that the symbol
    matcher names `checkmark`.
  - Both need a text line right after them on the row. Without one, an empty avatar or a color well
    passed.
  - What OCR made of the mark ("v", "✓", or as the first word of the label) is dropped.
  - Not covered: a box whose two states differ only in color (a gray check mark and a colored one).
  - The line is the box, and pressing taps its center. In the test app that did nothing at first, or
    toggled another row: an empty box's inside was transparent and not part of the button. That was
    the app's fault (fixed with a content shape), but a real app can do the same, so SKILL.md says to
    fall back to the label.
- **Page dots** (`RegionMap.pageDots`), `[page dots] 2 of 7`. Three or more blobs 4–12 pt high in a
  row with equal gaps, one of which differs from all the others in color or is wider (a pill). A row
  where all look alike is an ellipsis or a password and is left alone; rows inside a text line are
  the dots of ":" and "i". When no dot stands out, #65's `[page dots] 13` is still what's listed.
- **The selected one of a row** (`ScreenState.selected`), `[selected] <text>`. Three or more short
  lines on one row, evenly spaced, where exactly one differs from every other in what's behind it
  (a segmented control's pill, a chip, a picked day) or in text color, and the others agree.
  - Text color alone counts only with more evidence: a bar under the item, or the row is in the
    bottom 12% of the screen (a tab bar). Without that, one bold store name among five was "selected",
    and so was a red price.
  - A number needs something behind it: today's date in red and the current hour in bold aren't
    choices.
  - The color behind a line is the most common one along its frame's edge. Taken over the whole
    frame, a filled glyph's own body was the "background", and Clock's alarm icon was selected.
  - Text color and background are judged separately. Over a glass tab bar the backgrounds all differ
    a little, which hid a tab that was plainly tinted.
  - Icons are compared with icons, so a tab bar without captions works too.
  - A neutral line between two tinted ones is a title between links, and the navigation bar's row
    (above 96 pt) is skipped.
- **Sliders** (`ScreenState.sliders`), `[slider 40%]`, framed on the knob so its cell is where to
  start a drag. Two bars 3–8 pt thick on one line with a gap of 12–64 pt between them.
  - The bars differ in color (the filled part is tinted). Two bars of one color are a dashed line or
    a road on a map.
  - One color right above and below the track along its length. App icons' artwork (a lens, a map)
    always had two bars and a gap somewhere, on changing ground. The samples stay 8 pt away from the
    gap: the knob is taller than the track and has a shadow.
  - A bar is followed pixel to pixel, since a tinted track has a slight gradient, and measured from
    its middle row: a rounded bar's first row is a blend with the page.
  - Longest pair first, one slider per bar. A speaker glyph's stroke before the track made a second
    slider with the filled part.
  - Within about 3% of the app's own value. At 0% or 100% there is one bar, which can't be told from
    an underline or a progress bar, so the slider isn't listed.
- **A popup over a dimmed screen** (`ScreenState.popup`). The list ends with `(a popup is up around
  F14, over a dimmed screen. On it: @t36 @t37 … )`, also after an action that changed nothing.
  - An app dims the page with a black layer of 40% or more. White becomes a mid gray, and nothing
    under the layer is brighter than that gray. So: the most common color is a neutral gray between
    70 and 190, nothing brighter is as common, and what is brighter sits together in one place of
    3–75% of the screen.
  - A navigation or tab bar the layer doesn't cover is ignored; other bright areas mean an ordinary
    page with a gray part.
  - Small bright pieces within 72 pt of the card are its close button on a translucent disc. With no
    flat color around it the shape finder never saw it (#65); it gets a `[circle button]` line.
  - Not looked for: the lighter dimming behind a system alert or sheet (white stays above 190, as
    light as a keyboard), and dark mode, where the page is black either way. Their buttons are listed
    anyway.
- **An icon read as a word's first letter** ("쓰파리" for an airplane before "파리"). When a line's
  first character isn't ASCII and has another text color than the rest on the same background, it's
  listed as `[icon]` and the rest as its own line (`TextRecognizer.lines`). An icon in the text's own
  color still joins the word.

Not fixed: a slider at either end. Selection shown only by weight or size. Tabs that OCR merges into
one line ("Chicken Chinese" as a single line) can hide which one is selected. A popup in dark mode.

### 67. Keeping the device from auto-locking: input works, settings and power assertions don't

An agent that thinks for a minute between commands lost the device to a short Auto-Lock. Asking the
user to set Auto-Lock to Never works but is one more chore, so we looked for a way to hold it off.

- **No setting to change.** Neither CoreDevice's features and actions nor the lockdown services the
  device exports cover Auto-Lock or Focus / Do Not Disturb.
- **A power assertion doesn't hold the screen.** `com.apple.mobile.assertion_agent` answers
  `CommandCreateAssertion` with `ErrorKey: InvalidRequest` for `PreventUserIdleDisplaySleep` and
  accepts `PreventUserIdleSystemSleep`, but with that held and Auto-Lock at 30 s the screen still went
  off within 75 s. Over USB this service needs the TLS of its `AMDServiceConnection` for real (raw
  bytes get a TLS alert back), unlike the accessibility service (`CMobileDevice.c`); its `.shim.remote`
  can't be opened (#20).
- **Attention Aware Features hide the result.** With them on and the owner in front of the phone, the
  screen didn't go off at all, with or without anything sent. Test with them off.
- **What works: an all-released keyboard report** on the keyboard surface (#11). With Auto-Lock at
  30 s the screen went off 40–60 s after the last input; one report every 20–25 s kept it on for
  175 s. The report types nothing, the on-screen keyboard stays up with its input source unchanged,
  and a screen that is already off stays off.

The daemon sends one every 20 s to each device that got a command in the last 5 minutes
(`KeepAwake`, `daemon --keep-awake`). It only runs in the daemon; a plain CLI run doesn't keep the
device awake between commands.

### 68. Latin typed as jamo with no warning: a suggestion echoed the word, and merged key labels

Two failures found by driving third-party apps, both on an iPhone whose HID keys typed Dubeolsik
there:

- **A translator echoed the word.** "Where is the nearest subway station?" came out as
  "ㅉㅗㄷㄱㄷㅑㄴ…", and the app at once listed "did you mean: where is the nearest subway station?"
  under it. Both the probe (`OnScreenKeys.type`) and the warning (`KeyboardLanguage.latinAsJamo`)
  took the word on the screen as proof the letters came out as letters, so the rest was typed as
  jamo too and nothing was printed. Now a line whose Hangul, read back as Dubeolsik keys, spells the
  typed letters settles it: the whole first word for the probe, the first or last five letters for
  the warning (fewer letters turn up in ordinary Korean: "dks" is just 안).
- **OCR merged the Latin key labels.** Settings' search (the bar sits right above the keyboard) read
  the Latin keyboard as "QWERT", "• P", "ASDF", "GH", "J", "K", "Z", "X C", "V", "BN", "M". `fit`
  counted only single-letter lines, found five keys, needed six, and gave up tapping, so the HID keys
  typed "Bluetooth" as "ㅠㅣㅕㄷㅅㅐㅐㅅㅗ". A line of 2–10 letters is now split into labels spread
  evenly across it, the first and last half a label in from its ends (`OnScreenKeys.labels`). The
  same applies to merged jamo labels.

Checked afterwards on that device: "Where is the nearest subway station?" in the translator,
"abcde", "Wi-Fi 설정" and "Bluetooth" in Settings' search, and "대한민국 Seoul 지하철" in an
encyclopedia app's search, all typed as given.

### 69. A new screen holds still while it loads

Settling means two frames in a row look the same. A loading screen often does: an app's splash, an
article's blank page, a search's first results. An agent driving third-party apps got lists of 2–9
lines after `launch`, `press` and `type --enter`, and had to run `ui` again a second or two later.
Measured over USB (a capture takes 0.3–0.7 s):

- A delivery app's splash came about 1.7 s after `launch --restart`, held still for about 1.7 s,
  then the home screen replaced it and kept changing until about 6 s.
- An encyclopedia article went from the results (45 lines) through a blank page (6 lines) to the
  article (30 lines), then changed again a second later.
- Settings' About page settled, then changed about 1% of the screen a second later as values filled
  in. Settling again for that cost two seconds and read the same lines.

What `UIScreen` does now, only for a new screen (most of the screen changed during the wait
(`Settle.transition`), or most listed lines look different (`looksNew`), which also catches a change
that finished before the first frame):

- It looks once more, 0.2 s after settling. If 2.5% or more of the screen changed, it settles again
  and looks again (up to three times). Smaller changes are left alone.
- If the list then has fewer than 10 lines, it keeps watching for up to 3 s and settles again on any
  change. The line count comes from the read the list needs anyway, so a full screen pays no second
  OCR.
- After settling again, the early frames are dropped. They show the loading screen, and the
  moving-video rule (#49) read one of them for a home screen with a moving banner, so the list showed
  the splash.

Cost: a navigation in Settings went from about 3.8 s to about 4.9 s with the daemon (one more
capture). `launch --restart` of that delivery app takes about 8.5 s, but returns its home screen.

### 70. Popups #66 missed: a large card, and a tip with no card

Two dimmed screens in third-party apps got no note after the list:

- **A large coupon card.** The page behind was dimmed to gray 128, the most common color (38% of
  the screen), but the white card was big enough that brighter pixels were 57% as common as that
  gray, and `popup` wanted them under half. Now they only have to be less common than the gray; the
  card and stray checks that follow still keep an ordinary page with a gray area out.
- **A tip with no card.** A results page was dimmed to gray 100 over 70% of the screen, with white
  text ("check the map and favorites"), an outlined OK button and the pointed-at control left
  bright. `popup` found no card of 3–75% of the screen. `ScreenState.overlay` now takes such a
  screen (the gray covers at least half, anything brighter is under 10% as common) and names the
  lines whose text or background is well above what the layer allows (40 levels over: a dimmed
  blue badge with white text came just over the cap). If half the lines or more are bright, it's
  not a layer. The list gets its own note.

Checked on that device: both screens get their note; Calculator, Clock, Settings, the App Store,
Translate and five third-party apps' home screens get neither.

### 71. Relative paths went to the daemon's folder

The daemon runs each command in its own process, and that process's working directory is wherever
the daemon was started. `screenshot -o shot.png` run from another folder wrote the file into the
daemon's folder (here, the repository root), and `clipboard -o backup.txt` would put the clipboard
backup there too, where the agent's own file tools don't look. A request now carries the client's
working directory (`DaemonRequest.cwd`); the daemon switches to it for that command and back after.

### 72. A stepper's buttons came out as one line with its count

A guest count stepper (− 2 +, with round buttons) was read as one OCR line, "- 2 +", or "• 1 +" when
the − was disabled (an outlined circle reads as "•"). The list had one ref for the whole row, so
neither button could be pressed by ref, only by grid cell. `TextRecognizer.lines` now splits a line
made only of short numbers and signs, with at least one + or −, into its words: `[minus]`, the
count, `[plus]`. "•" counts as a − only in such a line, so a bulleted sentence is left alone. Vision
gave no box for the "+" of "• 1 +" (it did for "- 2 +"); a word without one gets a slice of the
line's box by character position.

### 73. `launch --restart` failed with "process identifier … could not be determined"

`launch <app> --restart` on a running third-party app failed with "The process identifier of the
launched application could not be determined. It may have already terminated." A second
`launch --restart` a moment later worked. `terminateExisting` seems to race with the app's own exit.
`AppService.launch` now waits 1 s after that error and launches once more without
`terminateExisting`; the old process is gone by then, so the app still starts fresh.
