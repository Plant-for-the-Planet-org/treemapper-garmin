# TreeMapper GPS for Garmin

A Connect IQ watch app that acts as a high accuracy GPS source for the
TreeMapper phone app.

This is the real thing: `Toybox.Position` drives the fix, `Toybox.Communications`
carries it to the phone, and `Application.Storage` holds anything the phone has
not acknowledged.

- [`PROTOCOL.md`](PROTOCOL.md) is the contract to implement the phone side against.
- [`TESTING.md`](TESTING.md) is the procedure for testing on a real watch.
- [`DESIGN.md`](DESIGN.md) is the architecture and the reasoning.
- [`docs-research/`](docs-research/) is the Connect IQ platform reference.

**The constraint that shapes everything:** `Position.enableLocationEvents()` is
limited to device apps and widgets, so a background service cannot turn the
receiver on. The watch app must be running in the foreground to produce a fresh
fix. A cold multi-band fix takes tens of seconds, so the app starts the receiver
on launch and keeps it warm for as long as it is open. Open it at the plot,
leave it running, and every request answers in milliseconds.

**It streams, and nobody has to touch it.** Once TreeMapper has said hello, the
watch posts its position every second until it is paused or closed. The person
opens it at the plot, sets it down, and works from the phone. There is no
per-tree press on the wrist.

**The watch stores nothing.** No outbox, no tree count, no session record. A
point is built from the receiver, handed to the radio and forgotten. One that
does not make it is dropped and counted, never retried, because by the time a
retry went out there would already be a fresher point waiting. The phone owns
the record; the watch is a sensor.

---

## Screens

| | Screen | Purpose |
|---|---|---|
| 1 | **Home** | A short splash. The receiver and the stream already started in `onStart`, so this holds for 1.5 s then advances on its own. START skips it. |
| 2 | **Acquiring** | Sweeping arc while the receiver converges, with an elapsed counter so slow is distinguishable from broken. Advances on a real fix, or after 90 seconds with any position. |
| 3 | **Stream, live** | The session screen. Quality ring, the quality word, the interval, a climbing count of points sent, and a status line that is always present. START pauses. |
| 4 | **Stream, paused** | Ring goes grey, the count stops. Says the receiver is still warm, so nobody feels they have to leave it running. START resumes. |
| 5 | **Stream, no phone** | Same screen, status line says what is wrong: no phone in range, or TreeMapper not open. The stream sends nothing until the phone speaks first. |
| 6 | **End session?** | A native confirmation on BACK, because the watch sits unattended and one stray press should not quietly end a session. |

Plus a native `Menu2` for the quality warning threshold, and a small About page.

Static previews are in [`previews/`](previews/), but **they show the old
one-shot capture flow and have not been regenerated for the stream screens**.
`tools/preview.py` mirrors the drawing maths from `source/ui/UiKit.mc` in Python
as a review aid; it is not part of the app, and it needs updating to match.

---

## Design notes

**Almost everything is drawn in code.** No layout XML. The only bitmaps are the
launcher icon and the TreeMapper mark, which is the real asset rather than code
art so the watch matches the phone app exactly. The mark ships at three fixed
sizes and `Layout.markResource()` picks one from the screen width: the resource
compiler's `scaleX` takes a pixel format, not a fraction of the screen, so it
cannot scale relative to the display for us. One set of proportions in `source/ui/Layout.mc` derives every
position from the `Dc` dimensions, so the same binary looks right on a 208 px
Instinct and a 454 px AMOLED without per device resource folders.

**The quality ring has four segments, not a smooth gauge.** `Position.Quality`
is a discrete 0 to 4 enum, not a value in metres. A continuous gauge would imply
a precision the receiver does not report. Four steps is the honest picture.

**Black background throughout.** Cheapest on both memory in pixel and AMOLED
panels, and it makes the green carry the whole interface.

**Two greens, on purpose.** `Theme.GREEN` is the brand `#007A49` and carries
everything with mass: the rings, the fills, the mark. `Theme.GREEN_LIGHT` is the
same hue lifted, and is used only for small captions and thin hints. At one or
two pixel weights on black, `#007A49` drops below comfortable contrast outdoors.
If strict brand fidelity matters more than sunlight legibility, set
`GREEN_LIGHT = GREEN` in `Theme.mc` and nothing else changes.

**The status line is always shown, and that is a deliberate reversal.** The old
capture screen only warned when something broke, on the argument that a badge
which is true on every screen stops being read. That argument holds for a screen
somebody is looking at while they press a button. It is exactly wrong for a
watch left on a stump for an hour: a link that quietly died looks identical to
one that is working. So the stream screen states its condition either way, and
when delivery goes quiet it says how long it has been quiet.

**Fades are colour blends, not alpha.** `Theme.blend()` mixes toward the
background. Alpha only arrived in API 4.0.0, and this app should run on older
products too.

**No haptics.** The watch confirms visually only. Vibration was removed on request; if it comes back, the place for it is `SessionState`, one call beside each send outcome.

**The stream does not run off the view's timer.** `SessionState` owns its own
`Timer`, so the cadence survives a view change, the settings menu being open and
the screen going dark. Views only draw.

**The render timer drops to 1 Hz when nothing is animating.** `StreamView` runs
at 50 ms only during the entry and pause transitions. With the receiver and the
radio both working all day, frames are the one cost here that can simply be
refused.

**Pausing leaves the receiver on.** Switching GNSS off would save the larger
share of the battery, but it would cost a cold reacquisition of tens of seconds
on resume, and the fix being already there is the whole point of the app. The
paused screen says "receiver still warm" so nobody avoids pausing to protect it.

**Back asks before it ends the session.** The watch is meant to sit unattended.
One stray press should not stop a stream nobody is watching, because the user
would not find out until they looked at the phone.

---

## Project layout

```
manifest.xml            products, permissions, entry point
monkey.jungle           build configuration
source/
  TreeMapperApp.mc      AppBase, entry point
  SessionState.mc       the brain: receiver, phone link, stream timer, counters
  GpsService.mc         Toybox.Position
  PhoneLink.mc          Toybox.Communications
  ui/
    Theme.mc            colour tokens, blending, quality mapping
    Layout.mc           screen metrics derived from the Dc
    UiKit.mc            drawing primitives: rings, spinner, tick, ripple
    Anim.mc             easings and a one shot timeline
  views/
    HomeView.mc
    AcquiringView.mc
    StreamView.mc       the session screen: live, paused, and what it is doing
    SessionMenu.mc      native Menu2
    AboutView.mc
resources/
  drawables/            launcher icon, white mark for dark screens
  strings/
tools/make_icons.py     builds the drawables from tools/source_icon.png
tools/preview.py        renders previews/, review aid only
previews/               static screen renders
```

---

## Running it

1. Install the Connect IQ SDK Manager (needs JRE 11 or newer) and the **Monkey C**
   VS Code extension, then run `Monkey C: Verify Installation`.
2. Open this folder in VS Code.
3. `Monkey C: Edit Products` and pick the devices you actually have. The list in
   `manifest.xml` is a starting guess and the ids are not validated until you do
   this.
4. Run with **Ctrl+F5** (Windows/Linux) or **Cmd+F5** (macOS) with a `.mc` file
   focused.

In the simulator, use *Simulation > Position* to feed coordinates and
*Simulation > Bluetooth* to fake the phone link. To exercise the real protocol,
drive it from the Android SDK's ADB transport; see `PROTOCOL.md`.

### Expected build warning

```
WARNING: The launcher icon (128x128) isn't compatible with the specified
launcher icon size of the device (60x60). The image will be scaled.
```

This is cosmetic. Every product asks for a different launcher size, and a clean
downscale from 128 beats shipping one small icon that gets scaled up elsewhere.
Once the device list is final, add a `resources-<product>/drawables/` folder per
device with the exact size that product wants and the warning goes away.

---

## How the pieces fit

```
TreeMapperApp        starts and stops the receiver and the stream with the app
  SessionState       the brain: owns the two below plus the stream timer,
                     and is the only thing views touch
    GpsService       Toybox.Position. Picks the best supported GNSS config,
                     keeps the receiver warm, hands out snapshots
    PhoneLink        Toybox.Communications. One parcel in flight at a time,
                     link state
```

Three rules run through it:

**One parcel per tick, and never two.** A tick that spends its slot answering
the phone does not also try to post a point. The BLE link returns
`BLE_QUEUE_FULL` if you push several at once.

**Nothing is stored and nothing is retried.** A point that cannot go now is
dropped and counted. `drop` counts only losses while the phone was in range, so
the number keeps meaning one thing: this interval is too fast for this link.

**The watch never filters on quality.** Every point travels with its
`Position.Quality` value and the phone decides what to keep.

## Not built yet

- No `Background` permission and no background service. Everything happens while
  the app is open, which is forced by the Position restriction above.
- No activity recording or FIT output. A FIT track would survive a dropped link
  and could be pulled later through Garmin Connect, but it needs the `Fit`
  permission, which moves the app into the device's Activities list.
- No retry of any kind. See the rules above.
- No measured battery figure for streaming. This is the open question that
  matters most; see `TESTING.md`.
- `tools/preview.py` and `previews/` still show the old capture flow.

---

## Supported devices

**Handhelds are the priority.** Watches are secondary.

The gate is not the marketing page, it is whether the firmware carries
`Communications.transmit` and `registerForPhoneAppMessages`. Check it in the SDK
device database at
`~/Library/Application Support/Garmin/ConnectIQ/Devices/<id>/<id>.api.debug.xml`
before adding anything.

| Handheld | Product id | Connect IQ | Multi-band reporting |
|---|---|---|---|
| GPSMAP H1 / H1i Plus | `gpsmaph1` | 5.0.0 | yes |
| eTrex Touch | `etrextouch` | 5.1.1 | yes |
| GPSMAP 86s / 86sc / 86i / 86sci | `gpsmap86` | 3.0.8 | no, see below |
| GPSMAP 66s / 66i / 66sr / 66st | `gpsmap66` | 3.0.8 | no, see below |

On the two 3.0.8 products the Position configuration API does not exist at all,
not even `CONFIGURATION_GPS`. The app cannot request a constellation and cannot
ask which one is in use, so it runs on the device default and reports
single-band in `ready`. That is a limit of what the firmware exposes, not a
measurement of the hardware.

### Will not work, and cannot be made to

| Device | Why |
|---|---|
| GPSMAP 67 / 67i | No phone app messaging in firmware |
| Montana 7 | No phone app messaging in firmware |
| Oregon 7xx | No phone app messaging in firmware |
| Rino 7xx | No phone app messaging in firmware |
| **GPSMAP 65 / 65s** | **Not a Connect IQ device at all.** No entry in the SDK device database, runs no Connect IQ apps of any kind. Garmin Connect shows it as incompatible. Nothing in this repo can reach it. |

The first four compile without complaint and fail at runtime, which is why they
are listed here rather than left to be rediscovered.

---

## Open questions

- **How much accuracy do the 3.0.8 handhelds actually give?** GPSMAP 66 and 86
  run on their own constellation choice because they have no configuration API,
  and the app cannot report what they picked. Only a field test answers whether
  they are worth deploying. See the device table above.
- **Brand green.** `Theme.GREEN` is `#007A49`. `Theme.GREEN_LIGHT` is a lifted
  variant used only for small text; see the design notes above.
- **Does 1 Hz hold, and what does it cost?** Both have to be measured on real
  hardware before the default interval is settled. The watch takes a `rate`
  command precisely so the answer can change without a new build.


---

## Regenerating the icons

`tools/source_icon.png` is the TreeMapper artwork as supplied: the white glyph on
the brand green field. `tools/make_icons.py` derives everything else from it.

```bash
python3 tools/make_icons.py
```

It writes the 128 px launcher icon, plus white and green glyph-only versions on
transparent backgrounds. The app draws the white one, since every screen is
black. Replace `source_icon.png` and rerun to change the artwork.
