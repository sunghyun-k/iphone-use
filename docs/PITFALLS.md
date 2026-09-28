# Pitfalls and reverse-engineering notes

Everything here was observed directly on real devices. None of it is in public documentation,
because there is none. The entries are numbered so code comments can cite them as `PITFALLS #N`.

If some code looks odd, read the matching entry before "fixing" it. Most of these spots have
already broken once. Add new entries at the end with the next number, and never renumber the
existing ones, because comments point at those numbers.

A few entries mention commands that were removed later. The findings still explain today's
code.

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
Korean Dubeolsik, so `wifi` came out as `쟈랴` (the Hangul on those key positions); the iPad
(iOS 26.6) is always English, so the Dubeolsik keys `qoxjfl` came out literally as `qoxjfl`.
`ctrl+space`, Caps Lock, Globe (Consumer 0x29D) and LANG1/LANG2 (0x90/0x91) switch **only the
on-screen keyboard's language.** Typing on the Dubeolsik layout while an English input source is
active gives uncomposed jamo such as `ㅈㅑㄹㅑ`.

So `text` decomposes Hangul into Dubeolsik key positions (`HangulKeys`): on a device with a Korean
layout you get Hangul, on one with an English layout you get Latin letters. Digits and symbols sit
in the same positions on both layouts, so they work everywhere. Shift combinations land exactly
(`!`, `_`, `?`, Shift+Q → `ㅃ`).

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
went through the Korean layout and came out as `ㅍ` (the Hangul on the V key). Send it the way a
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
  "Invoking action" and never "Received reply"). Instead we call the old lockdown
  `installation_proxy` through the shim (`Browse`, several messages until `Status: Complete`).
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
even a ⌘V paste (user input) triggers the prompt "'설정'이(가) 'dtpasteboardd'에서 붙여넣으려고 함"
("Settings" would like to paste from "dtpasteboardd"). An agent must not allow that prompt on the
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
  filtering descriptions (6 s to the end of the Settings root screen, capped at 300 elements).

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
  event's `AccessibilityIdentifier_v1`). `back` tries the identifier, then an edge swipe (checking
  that the screen changed); if neither works it presses nothing and reports the top-left element,
  because in some apps the top-left isn't Back (in some apps, e.g. a social app, it's a "side menu").

#### Keyboard keys

- **Keyboard keys are elements too** (`ㅂ, 사운드 재생, 키보드 키`: "ㅂ, play sound, keyboard key").
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
  `AXCustomAction-Name:추가 정보\nTarget:0x…\nSelector:…` ("More Info"). Running it with
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
  last part of its description, "키보드 키" / Keyboard Key) and the leading run of elements carrying it,
  plus unnamed ones between keys, is skipped. Walks from the end (`end()`) skip it the same way.
- **Stepping back 20 elements scrolls the chat up by 20 elements.** With the keyboard up, a message
  that had just been sent ended up off screen. After the sweep, focus walks forward to the last swept
  element so the chat is back at the bottom (about 1 s).
- In a list taken from the end, `--more` walks backward from its earliest element and puts what it
  finds in front, and after an action the older messages that slide into the window aren't reported as
  `added`. A list from the end applies to that screen: when an action leads to a different screen, the
  new one is listed from the start as usual.

## Permissions

DeviceHub.app has **empty** entitlements. All trust is handled by the pairing record and the
`CoreDeviceService` daemon. `axAuditService.xpc` holds
`com.apple.private.accessibility.remoteDeviceContent` and others, but the device side has no way to
verify host entitlements (lockdown/DTX carry no code-signing information), so that is only a local
macOS gate. In practice a bare client can read everything.
