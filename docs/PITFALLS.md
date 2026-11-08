# Pitfalls and reverse-engineering notes

Everything here was observed directly on real devices. None of it is in public documentation,
because there is none. The entries are numbered so code comments can cite them as `PITFALLS #N`.

If some code looks odd, read the matching entry before "fixing" it. Most of these spots have
already broken once. Add new entries at the end with the next number, and never renumber the
existing ones, because comments point at those numbers.

A few entries mention commands that were removed later. The findings still explain today's
code.

The accessibility path (the "AX protocol" and "AX pitfalls" sections and #35–#47) was removed in
favor of OCR on screenshots (#48). Those entries stay as a record of what was tried; no code cites
them anymore, except #42 for comparing an area between two frames.

## AX protocol

The RPC surface of `com.apple.accessibility.axAuditDaemon.remoteserver` can be read straight
from the `AccessibilityAuditDeviceManager` binary, where the selector names are left intact.

Host → device:
```
deviceInspectorMoveWithOptions:                  tree traversal (direction/allowNonAX/includeContainers)
deviceElement:valueForAttribute:                 read an attribute value
deviceElement:setValue:attribute:                write an attribute
deviceElement:performAction:withValue:           perform an action (AXAction-2010 = Activate)
deviceFetchElementAtNormalizedDeviceCoordinate:  coordinate hit test (requires NSValue<CGPoint>)
deviceInspectorFocusOnElement: / PreviewOnElement:
deviceSetAuditTargetPid: / deviceSetAuditUIPid:
deviceRunningApplications / deviceAccessibilitySettings
```

Device → host:
```
hostInspectorCurrentElementChanged:
hostInspectorCurrentElementPropertiesChanged:
hostDeviceFrontmostAppPidDidChange:
hostFoundAuditIssue:
```

Element properties arrive grouped into sections: Basic (Label/Value/TraitsHumanReadable/Identifier/Hint/
UserInputLabels), Actions, Element (class name / memory address / view controller), and Hierarchy
(`_AXHierarchyElementsAttribute` → walk children via `ChildrenValue_v1`).

## AX pitfalls

### 1. Session state is sticky

If a dead pid is left in `deviceSetAuditTargetPid:`, it stays in the daemon even after the client
exits, and **blocks focus events for every later connection.** Always reset it to 0 when a
connection starts and when it ends.

### 2. It competes with Accessibility Inspector

Stateless calls coexist fine, but a focus session is exclusive: whichever side grabs it, the other
starves.

### 3. Host and device protocol versions drift independently

An iOS 27.2 device reported `deviceInspectorEnable:` in its capabilities, a string that does not
exist in the Xcode 27.0 framework. Ask for capabilities first and branch on them.

### 4. Overlapping moves break the daemon

If a second `deviceInspectorMoveWithOptions:` is sent before the focus event for the previous one
arrives, every later `deviceElement:valueForAttribute:` returns an empty response (no payload,
errorStatus 0). It does not recover until the connection is reopened. While waiting for a focus
event, do not mistake some other event (such as `hostInspectorMonitoredEventTypeChanged:`) for
"the move failed" and resend the move.

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

## HID pitfalls

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

## Wi-Fi pitfalls

Wi-Fi uses the same path: `remotepairingd` hands out tunnels for Wi-Fi devices too. What differs is
latency and packet timing, and that broke several things that only worked on USB by luck.

### 15. The HID service drops the connection after replying, then goes quiet

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

`AMDeviceNotificationSubscribe` only reports USB devices. So lockdown services (the accessibility
daemon, installation_proxy, etc.) are opened on the port the device advertises in RSD as
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

## iPad pitfalls

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

## Device, connection and daemon pitfalls

### 25. Capture succeeds even when the screen is off

The device returns a black image with no error, and an agent reading it goes looking for elements
that aren't there. A nearly black capture is an error in `wait` and a warning in `screenshot`/`--shot`.

There is no good way to detect the lock state. The `getlockstate` feature is rejected by the device
as "not implemented", and accessibility's `deviceRunningApplications` returned an empty array
whether locked or not. MobileDevice's `AMDeviceValidatePairing` failing with 0xE8000025 is not a
lock signal either: the iPad failed with the same code while unlocked (looks like a lockdown pairing
record problem). So accessibility commands fall back to the tunnel path when USB lockdown fails.

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

## Input and gesture pitfalls

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

## Finding and pressing elements

### 35. Accessibility gives no element coordinates

What we found while trying to tap elements by name (iOS 27.2):
- There is no frame attribute. The inspector exposes only Basic/Actions/Element/Hierarchy, and
  asking for `AXFrame`, `Frame` or `AXActivationPoint` directly returns nil. It is still nil when the
  attribute descriptor's `ValueTypeValue_v1` is varied from 0 to 8.
- The hit test `deviceFetchElementAtNormalizedDeviceCoordinate:` only returns an empty answer (16
  bytes, errorStatus 0). Adding monitored event types (0, 1, 2), `deviceInspectorEnable:` or
  `deviceInspectorInformCurrentCursorPosition:` changed nothing, on both the home screen and
  Settings. `deviceFetchResolvesElementsOnSimulator` is 0 in the capabilities, so it looks
  simulator-only.
- `deviceFetchSpecialElement:` returns the app's first element (the header) for 0 and 1, nil for
  everything else.
- Writing a value with `deviceElement:setValue:attribute:` is silently ignored, just like
  `performAction` (even on the Settings search field).

So element rects are measured from the boxes the inspector draws on screen instead (#36, #37).

### 36. The inspector's yellow preview box shows an element's rect

There is no accessibility request that returns coordinates (#35), but
`deviceInspectorPreviewOnElement:` draws a translucent yellow box the size of the element on the
device screen. Compare screenshots before and after: the bounding box of the pixels whose yellowness
(red minus blue) increased is the element's rect. `press` falls back to this when the green focus
box (#37) can't be measured. Findings:
- The yellow preview box and the inspector's green focus box **stay on screen after the session
  closes.** Only `deviceInspectorShowVisuals: NO` clears them. Leave them and the user has a yellow
  box floating on their screen.
- Don't locate the element from all changed pixels. The green focus box drawn while moving focus
  disappearing also counts as change, and once that returned the search field's rect instead. Count
  only the pixels that got more yellow.
- Jumping focus straight to a distant element with `deviceInspectorFocusOnElement:` doesn't make the
  view scroll along, and the box was drawn off screen. Walk to the element step by step instead. On
  such a walk the first focus event sometimes arrives more than 1 s late, so the wait is retried a
  few times (otherwise it stops on the first element and measures the wrong place).
- Audit (`deviceBeginAuditCaseIDs:`) also delivers `ElementRectValue_v1` (an `NSRect` in points) in
  `hostFoundAuditIssue:`, but **only for elements with an issue.** Element tokens obtained from an
  audit only have readable attributes in a session with focus monitoring enabled.
- If focus is already on the first element, a "move to first" (`direction 5`) produces no event,
  because focus didn't change, and the second of two back-to-back commands failed with "no focus
  events arrive". When no event comes, focus now steps away and back (#37).
- No focus events arrive on the home screen (SpringBoard) (iPadOS 26.6). The lock screen and apps
  work. If no element is picked up, the command fails with `ScanError.noFocusEvents` rather than
  returning an empty list, because an empty list reads as "no such element".

### 37. The green focus box shows an element's rect

Findings from measuring elements while stepping focus through a screen:
- Moving focus makes the inspector draw a green focus box around the element. Compare a frame with it
  shown and a frame after clearing it with `deviceInspectorShowVisuals: NO`: the bounding box of the
  pixels that **lost green** is the element's rect. In Settings › General it matched the OCR
  coordinates within a few pixels.
- The green box is drawn **only when focus changes.** Turning ShowVisuals back on after clearing, or
  sending `deviceInspectorFocusOnElement:` for the same element, didn't redraw it. So an element that
  already has focus is measured with the yellow preview box (#36).
- **"Move to last" (direction 6) is unreliable.** In Settings › General it went to the first element
  (the back button), and when already on the first element there was no event at all. So the
  workaround "no event because already first → go to last and back" (#36) failed completely on that
  screen with "no focus events arrive". It now steps one forward and back instead, and nothing
  relies on "move to last".
- For both the green and yellow boxes, don't take the bounding box of all changed pixels. A Live
  Activity in the Dynamic Island (a music waveform) extended right below the status bar and kept
  moving, and the "General" row got measured from the very top of the screen down to that row
  (1172x1329). Only the single largest connected region of changed pixels is used
  (`AXWalker.largestRegion`).
- iOS 16.7 (iPhone X) has no CoreDevice tunnel, so even `screenshot` fails, but accessibility works
  over USB lockdown. `scan` and `ui` run; measuring rects needs screen capture and
  doesn't. Such a device shows up in `devices` (via MobileDevice) but can't be selected by name,
  because name resolution only looks at the CoreDevice list; pass the UDID.

### 38. Driving the device from the accessibility list alone (`ui`, `press`, `type`, `back`)

The commands that found targets by OCR (`find`, `tap "text"`, `wait "text"`, `tap --ax`, `focus`)
were removed; targets are now pressed by their ref in the element list. The list is stored in
`~/.iphone-use/ui-<udid>.json` as ref, token and description. To press, it walks from the focus
position left on the device to the target, then measures the rect with the green focus box (#37).

#### Tokens and list identity

- **The first 4 bytes of a token are the app's pid** (little-endian). Settings (pid 36934) is
  `46900000…`, SpringBoard (pid 39) is `27000000…`. Matching the pid against executables from
  `listprocesses` gives the app name, and `back` is refused on the home screen (an edge swipe from
  the left opened the widget screen).
- **The same element can get a new token.** After sweeping the Settings root screen to the end and
  coming back, the Apple Account row had the same description but a new token (looks like cell
  reuse), and a list taken moments earlier stopped with "the screen changed since the list was
  taken". While walking, an element **at the same position with the same token or the same
  description** is treated as the same element and its token is updated. Diffing (`observe`) also
  pairs by token first, then by description. Conversely, the navigation bar's back button **keeps the
  same token across screens**; only its name changed ("Settings" → "Back").
- **A messenger app's chat list changes even while walking.** Counting steps and checking at each one
  drifted, so on a mismatch it seeks by description from the start (`seek`; when several share a
  description, by which occurrence it is). `ui --find` also sweeps in one pass instead of continuing a
  walk.
- **Nearby-device and network lists gain and lose rows while walking.** Even with a fresh list,
  `press` stopped with "the screen changed since the list was taken". It seeks by description the same way.

#### Walking and scrolling

- **When focus moves to an off-screen element, the view scrolls only just enough to show it.** Walking
  back up from the end of the list to "General", the row ended up half under the translucent
  navigation bar, and the tap hit the bar. It now goes three more steps in the walking direction and
  comes back (50 ms per step). The first attempt dragged the content to the middle instead, but that
  cost 4 more seconds because the back button attached to the bar was checked by dragging too.
- **There is no direct way to the end of the list.** In the iOS 26 Settings app the search field is in
  a bar at the very bottom of the screen, so it's at the end of the focus order (36th of 37), and the
  close button during search comes just before the keyboard keys (around 70th). A subagent called
  `--more` four times looking for the search field. Sending `previous` from the first element doesn't
  wrap and produces no event, and `last` produced none either. So `ui --find` walks from the start,
  filtering descriptions (6 s to the end of the Settings root screen). It was capped at 300 elements;
  now 100 per call, and `ui --find … --more` searches the next 100, so a miss costs 5 s instead of 15.

#### Measuring and timing

- **For full-width rows the green box splits into two horizontal lines.** The left and right edges
  are clipped by the screen edge and the fill is faint, so picking only the largest region measured a
  row in a messenger app's chat list as its top border line (1290x16). The swipe then landed there
  and opened the neighboring chat. If the largest region is a thin horizontal line, it is merged with
  its partner line spanning the same x range (`largestRegion`). A rect with a side under 24 px is
  never tapped (`UIScreen.measure`).
- **Scrolling is judged from the box surroundings only (160 px).** Looking at the whole screen, an app
  whose home screen plays a looping video of a person always read as "scrolling" and fell through to
  the yellow preview box; the face (skin tones are quite yellow) was then taken as the preview box, and
  a tab bar item was tapped in the middle of the video (two out of four times). The green box itself
  was right every time. When the view scrolls, the content next to the element moves too, so the
  surroundings are enough.
- **Timing.** In the daemon one `press` takes 5–8 s: walk 0.1–0.8, measure 1.5 (one capture is 0.5 s,
  two frames with the box shown and cleared; if the area around the box differs between the two
  frames, the view is scrolling, so it re-measures on a settled frame with the yellow preview box),
  tap 0.1, wait for the screen to settle 2 (a running Live Activity in the Dynamic Island delays the
  verdict by a frame or two), re-sweep 1. Box detection runs at half size: scanning 3.6 million
  pixels at full size took over 0.5 s per pass in a debug build.

#### Going back

- **The UIKit back button's identifier is `BackButton` regardless of language** (from the focus
  event's `AccessibilityIdentifier_v1`). `back` tries the identifier, then (since #43) a back label
  instead of the edge swipe it once used; if neither works it presses nothing and reports the top-left element,
  because in some apps the top-left isn't Back (in some apps, e.g. a social app, it's a "side menu").

#### Keyboard keys

- **Keyboard keys are elements too** (on a Korean device, a jamo followed by the Korean for "play sound, Keyboard Key").
  They come last in focus order, and the focus event has no numeric traits value, so there was no
  language-independent way to filter them. They stay in the list, and whether the keyboard is up is
  judged from single-character rows at the bottom of the screen (`TextRecognizer.keyboardVisible`;
  it doesn't pick targets).

#### Row-end ⓘ buttons

- **ⓘ isn't an element; it's attached as an action.** Tapping a Bluetooth or Wi-Fi row
  connects/disconnects, and the settings are behind ⓘ. Right after launching Settings fresh, the
  device-side `next` in the Bluetooth list skipped the ⓘ on the AirPods row (the one on the Watch row
  sometimes appeared), and the ⓘ on a Wi-Fi row is never an element. Instead, the inspector
  `Actions_v1` field of the focus event has a custom action
  `AXCustomAction-Name:<"More Info" in the device language>\nTarget:0x…\nSelector:…`. Running it with
  `performAction` is silently ignored, like activation (`AXAction-2010`) (#35). So it measures the
  row and taps **within 0.6× the row height from the right edge** (on a 164 px row the ⓘ center is
  100 px from the edge, confirmed by drawing on a screenshot). For Bluetooth the selector is
  `_accessibilityHandleDetailButtonPress:`, so `--action` finds it automatically; on Wi-Fi it's
  attached as a block with `Selector:(null)`, indistinguishable from other actions, so the caller
  uses `--trailing`.

#### Swipe-revealed buttons

- **Swipe-revealed buttons (`press --swipe`).** Custom actions (Delete, Leave) can't be performed, so
  it swipes the row by only 35% to reveal the buttons, then taps. Findings:
  - The buttons appear in focus order **right after the swiped row**, with names (a messenger app's
    "Leave, button"; Messages' "Hide Alerts" and "Trash"). Only elements with no actions that lie
    within the swiped row's height count as buttons: in the messenger app the next item was another
    chat row.
  - The small scroll that follows focus didn't close them, but sweeping again from the start so that
    **the row left the screen and came back** did. So there's no re-sweep after swiping, and revealed
    buttons are tapped at the rect measured during the swipe instead of walked to.
  - At **the moment focus first lands on a button** the rect can't be measured (nil). Stepping one away
    and back measured it exactly as 150x150.
  - Near the bottom tab bar the box is partly covered and measures wrong. The row is dragged to the
    middle before swiping, and if it still doesn't look like a row, it doesn't swipe.

#### Grid fallback

- **When the image is the only option, pick a grid cell (`screenshot --grid`, `touch --cell`).**
  Guessing pixel numbers on a downscaled image misses by tens of pixels, multiplied by the downscale
  factor. Cells are defined in device pixels (10 cells on the short side, 129 px on iPhone), so they
  point to the same place however far the image is shrunk. Labeling every cell covered the small text
  and icons underneath, so like a chessboard the labels go only in the outer margin on all four sides,
  and every fifth line is thicker so the 22 vertical cells can be counted in chunks.

#### Daemon session

- **The daemon holds the accessibility session open on the tunnel path**, because opening one takes
  about 1.3 s. The lockdown path only lives inside a MobileDevice session block and can't be held.
  Each request drains queued events and clears the audit target pid. Unless the error is one where we
  chose to stop (`KeepsSession`), the session is released.

### 39. Walking past the end of a page turns a horizontal pager

In Weather (one page per city, iOS 27.2), focus order runs through the pages in sequence: the page
indicator in the bottom bar, the visible page's content, then **the next page's content**. When `next`
crosses from the last element of one page to the first of the next, the pager scrolls to that page,
just as VoiceOver does. No event marks the crossing: nothing arrives besides
`hostInspectorCurrentElementChanged:`, and the tokens and descriptions don't tell pages apart.

- Every `ui --find` swept to the end, and the wrap back to the first element didn't scroll the
  pager back, because that element (the page indicator) sits outside the pager. Each sweep left the
  app one page further on, and a few sweeps ended on the last city. Now, when a sweep wraps
  (`walkFromFirst`, `ui --more` reaching the end), focus steps onto the second element and back. That
  element is the start page's first content, and stepping onto it scrolls the pager back.
- Jumping focus (`deviceInspectorFocusOnElement:`) to a start-page element, then stepping from it,
  did **not** turn the pager back. Only crossing a page boundary with `next`/`previous` does. A sweep
  that stops at `findLimit` without wrapping can still leave the app on another page; walking back
  would cost as many steps as the sweep took.
- The list is still in focus order, so it includes later pages. `ui` right after swiping to page 2
  sometimes listed page 1 first, and the sweep brought page 1 back.

### 40. Over a translucent bar the green box is too faint at half size

In a messenger app's chat screen (iOS 27.2), `type` into the message field and `press` on its send
button both stopped with "could not measure the element". The field and button sit in the translucent
bottom bar. The green box was drawn, but its border there is only 1–2 px thick and raises the green score
by about 45, and much less over the button's yellow fill. Halving the frame averages the border with its
neighbors down to about 22, under the threshold of 40, so nothing was found. The yellow preview box
didn't help either: the bar washes it out, and on the yellow button it doesn't stand out.

At full size and a threshold of 25, the field measured 704x98 and the send button 98x98, with the
blinking text cursor left out. `greenBox` now runs that pass when the half-size pass finds nothing, so
the extra full-size cost is paid only on screens like this.

### 41. Sweeping from the first element scrolls a chat to its oldest messages

A messenger app's chat screen (iOS 27.2) opens scrolled to the newest message, but `ui` (and the list
printed after `press`) starts with "move to first", so focus went to the header and then the oldest
loaded message, and the chat scrolled all the way up. The first 20 were the oldest messages; the newest
ones and the input field needed `--more`. In a long chat this may also make the app load older history.

- **"Move to last" works on such screens.** In that chat it went to the last bottom-bar button, and
  `previous` steps went input field → newest message → older, without the chat moving. It still lands on
  the first element in Settings › General (#37), so `walkFromLast` treats a first `previous` with no
  event (nothing before the first element, #38) as "last didn't work" and the caller falls back to a
  sweep from the start.
- **With the keyboard up, the end of the focus order is the keyboard.** About 40 keys, then the
  suggestion bar, then the app's own elements, so a sweep of the last 20 got only keys. Keys have the
  app's pid and no numeric traits (#38). Return, space and delete do carry language-independent
  identifiers (`Return`, `space`, `delete`), so the localized trait text is read off one of them (the
  last part of its description, "Keyboard Key" in the device's language) and the leading run of elements carrying it,
  plus unnamed ones between keys, is skipped. Walks from the end (`end()`) skip it the same way.
- **Stepping back 20 elements scrolls the chat up by 20 elements.** With the keyboard up, a message
  that had just been sent ended up off screen. After the sweep, focus walks forward to the last swept
  element so the chat is back at the bottom (about 1 s).
- In a list taken from the end, `--more` walks backward from its earliest element and puts what it
  finds in front, and after an action the older messages that slide into the window aren't reported as
  `added`. A list from the end applies to that screen: when an action leads to a different screen, the
  new one is listed from the start as usual.

### 42. A row can move between measuring and tapping

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

### 43. `back`'s edge swipe ran a chat row's swipe action

In a messenger app's chat list, a root screen with no back gesture, `back` found no `BackButton`
identifier and fell through to the edge swipe, which started at 45% of the screen height. A chat row
was there, and dragging it to the right ran the row's leading swipe action, "Mark as unread". The
screen changed (an unread badge), so `back` even reported "Back (edge swipe)".

- Moving the swipe up to navigation-bar height fixed that screen but not the idea: any swipe can land
  on something that reacts to it. `back` no longer swipes. After the `BackButton` identifier it looks
  for a button **labeled** as back among the first elements (the messenger's chat screen says "Previous,
  Button" in the device's language); apps that don't use the system back button still label theirs. Only the whole name counts
  ("Previous month" doesn't). If neither is found, it presses nothing (see #45 for what came after).

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

### 45. The top-left guess named the title, and some back buttons have only the previous title

When `back` found neither an identifier nor a "Back" label, it reported the top-left element as the
likely back button. On a SwiftUI detail screen that was the navigation title ("Details, Header"), not
the back button next to it ("Probe, Button"); an agent following the hint would press the title.

A toolbar back button an app draws itself (`navigationBarBackButtonHidden` + a leading button) has no
identifier and is named after the previous screen, like the system one. Its name says nothing in any
language, but we saw the previous screen: `UIState.trail` keeps the first four names of each screen
we left within the app, pops when the screen comes back, and `back` presses a leading element whose
name is among the top entry's. Two screens count as the same only if they share two names (or are
identical): a back button shares exactly one name, the previous title, with the screen it returns to.
The top-left guess is gone; with nothing found, `back` prints the list and presses nothing.

In the end the `back` command was removed. The trail can be wrong whenever the screen changed without
a list being taken (the user touched the device, `touch`, `swipe`), and then a button sharing the
previous title gets pressed. The agent has seen where it came from, so SKILL.md describes what a back
button looks like (a leading button named after the previous screen, "Back", Close/Cancel on sheets)
and the agent presses it with `press`.

### 46. A notification banner over the top of the screen takes the tap

A banner covers roughly 6–15% from the top of an iPhone for about five seconds. `press` on a toolbar
button while one was down opened the notification's app. The banner is not in the accessibility walk
(`ui` during a banner listed only the app), and the hit test returns nothing (#35).

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

### 47. Looking for a chat's back button swept the chat through its history

A list from the end (`--last`, #41) never reached a chat's back button, which is the first element.
An agent looked for it with `ui --find`. `--find` swept from the top for up to 100 elements: the
chat scrolled to its oldest loaded message, and the app kept loading older history.

We probed a messenger chat (iOS 27.2) one move at a time, comparing box-free frames after each:

- **Jumping to the first element** ("move to first") landed on the back button, and the screen didn't
  move. It held in three runs. Right after `press … --last` opened one chat, though, the jump sent no
  event: the app had already put focus on the first element, and a jump to where focus is sends nothing
  (#36). One step (to the title) and a jump back found it, so the code uses `AXWalker.first`.
- **Stepping on** through the top bar (title, search, call, menu) didn't move it either.
- **The next step** reached a date separator in the messages, and the whole chat scrolled up.
- **Jumping to the last element** brought the chat back to the bottom.

You can't tell where the top bar ends without taking that step, so only the first element is safe.

What the code does now:

- A list from the end that doesn't reach the start reads the first element with a single jump, then
  jumps back to the end (`UIScreen.readHead`).
- That element is printed above the list, marked as the first element.
- `press` on it jumps there again instead of walking (`goHead`).
- In a list from the end, `ui --find` keeps the direction and searches only what has been listed.

## Permissions

DeviceHub.app has **empty** entitlements. All trust is handled by the pairing record and the
`CoreDeviceService` daemon. `axAuditService.xpc` holds
`com.apple.private.accessibility.remoteDeviceContent` and others, but the device side has no way to
verify host entitlements (lockdown/DTX carry no code-signing information), so that is only a local
macOS gate. In practice a bare client can read everything.

## Reading the screen by OCR

### 48. OCR lists every line it read; the caller never guesses a string

The first OCR commands (`find`, `tap "text"`) took a string from the caller and tapped the line that
matched. They often pressed the wrong place: the guess matched several lines (a title and a row with
the same word), or OCR had misread the line the caller meant. That is why the accessibility list
replaced them. The accessibility path was then dropped for speed: walking focus to an element and
measuring the green box (#37) took 5–8 s per `press` and 2–3 s per list, and only the focus order
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

## Daemon input pitfalls

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

## Foldable iPhone

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

## Controls without text

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

## Input timing

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

## Device state

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

## Naming icons

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
