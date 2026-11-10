# Pitfalls archive: the accessibility path

These entries are retired. They describe driving the device through the accessibility audit daemon
(`com.apple.accessibility.axAuditDaemon.remoteserver`): walking focus from element to element and
measuring the inspector's boxes on screenshots. That path was replaced by OCR on screenshots
([`PITFALLS.md`](PITFALLS.md) #48) because it took 5–8 s per `press` and listed the focus order, not
what the screen showed. No code cites these entries.

They stay as a record of what was tried, so nobody walks the same dead ends. They keep their original
numbers; the live entries are in [`PITFALLS.md`](PITFALLS.md). The commands they mention (`back`,
`ui --last`, `AXWalker`) no longer exist.

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

## Entries

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
