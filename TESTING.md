# Testing on real hardware

Two separate exercises. The first proves the link works. The second proves the
watch is actually more accurate than a phone, which is the only reason this
project exists. Do them in that order, but do not skip the second: if the
accuracy gain is not there, the link working is irrelevant.

---

## 0. What to buy

One watch is enough to start. Two lets you compare.

The requirement is **multi-band GNSS (GPS L1 + L5)**. Single-band Garmin watches
will not reliably beat a good phone under canopy, so buying one would prove
nothing. At the time of writing that means roughly:

fēnix 7 Pro / 7X Pro, fēnix 8, epix Pro (Gen 2), Forerunner 955, Forerunner 965,
Enduro 3, Instinct 2X Solar, quatix 7 Pro, tactix 7.

**Do not trust that list, or the marketing page.** Verify on the actual unit:
the watch reports its own GNSS capability, and the demo app prints it. The
`ready` message carries `mb`, and the app shows **multi-band** or
**single-band** on the watch status line. If a new watch says single-band,
return it.

You also need an Android phone with **Garmin Connect Mobile** installed and
signed in. That is not optional for a real watch; see `PROTOCOL.md`.

---

## 1. Bench test: does the link work

About thirty minutes, indoors except for the last two steps.

### Set up

1. **Pair the watch in Garmin Connect Mobile.** Pairing in Android's Bluetooth
   settings is not enough; Garmin Connect holds the pairing.
2. **Build the watch app for that exact device.** In VS Code run
   `Monkey C: Edit Products`, select your model, then
   `Monkey C: Build for Device`. You get a `.prg`.
3. **Copy the `.prg` into `GARMIN/APPS` on the watch** over USB.

   On macOS, newer music-capable watches (epix, fēnix 7/8, FR955/965) **do not
   mount in Finder**. You need an MTP client: OpenMTP or Android File Transfer.
   This surprises everyone once.

   The file will vanish from `GARMIN/APPS` after you disconnect. That is normal
   on current firmware: the app is moved into storage you cannot browse. Check
   the watch's Connect IQ app list instead.

4. **Install the demo app** (`android-demo/`) on the phone, and leave the
   "ADB simulator" switch **OFF**. That is the real-watch mode.

### Run, in order, and stop at the first thing that fails

| # | Action | Expect | If it fails |
|---|---|---|---|
| 1 | **Find watch** | device name, `CONNECTED` | Watch asleep, or not paired in Garmin Connect |
| 2 | (automatic) | app line shows `installed vN` | The sideload did not take, or the app id does not match `manifest.xml` |
| 3 | **Hello** | `ready` arrives; watch line shows quality, **multi-band**, `live`, `every 1.0 s` | Nothing arrives: the watch app is not running. Open it on the wrist and retry |
| 4 | **Open watch app** | app launches on the wrist | See the note below, this is a real open question |
| 5 | (do nothing) | points start arriving on their own, about one a second, `gap` near 1000 ms | Nothing arrives: the watch sends nothing until it has heard `hello`. Outdoors yet? Indoors there may be no fix at all |
| 6 | Watch the wrist | `LIVE 1.0 s`, the sent count climbing, status reads **Sending to TreeMapper** | |
| 7 | Let it run 5 minutes | `n` on the phone matches the watch count; `drop` stays at or near 0 | A climbing `drop` means 1 Hz is too fast for this link. Record the number, then try step 10 |
| 8 | Press START **on the watch** | watch says **PAUSED**, points stop, `ready` arrives with `st=paused` | |
| 9 | Press START again | points resume within about a second, with no reacquisition wait | A wait here means the receiver was switched off, which pause must not do |
| 10 | **Ask for 2.0 s interval** | `ready` confirms `every 2.0 s`, the watch header reads `LIVE 2.0 s`, `gap` doubles | |
| 11 | Walk 30 m away | watch says **No phone in range**, points stop, `drop` does **not** climb | Nothing is buffered, and out-of-range time is deliberately not counted as dropped |
| 12 | Walk back | points resume on their own | |
| 13 | Press BACK on the watch | **End session?** confirmation appears, and only then does the app exit | It must not exit on the first press |

### The three numbers to write down

`drop` after an hour at 1 Hz, the typical `gap` between arrivals, and the
battery figure from section 2. Together they decide whether the default
interval stays at one second. The watch takes a `rate` command precisely so
that answer can change without shipping a new build.

### Two things to record while you are there

**Does `openApplication()` prompt the user?** Watch the wrist during step 4. The
documentation does not say, and the answer decides whether the TreeMapper modal
needs a "check your watch" state. This is the single most important unknown
left in the design.

**Does the stream hold at 1 Hz?** The point card prints a `gap` line: the
measured milliseconds between arrivals. If it sits near the interval the watch
reports, the link is keeping up. If it drifts well above, it is not, and the
watch's own `drop` count should agree.

**What type do the coordinates arrive as?** The point card prints a `type` line.
Right now the watch sends them as text (`SAFE_COORDS = true` in
`GpsService.mc`), a workaround for the simulator crashes. On real hardware, set
it to `false`, rebuild, and check whether `type` says `Double`. If it does, the
crashes were a simulator problem and you can keep the cleaner numeric form.

---

## 2. Field test: is the watch actually more accurate

This is the one that decides whether to buy fifty watches. It needs a plot with
canopy, because open sky is where phones already do fine.

### Method

Pick **20 to 30 trees** in a plot you can revisit, and mark each physically, with
tape or a peg, so you return to the same spot.

Record each tree **three times**:

1. TreeMapper on the Android device that shows poor accuracy today
2. TreeMapper on a good Android device
3. The watch, via the demo app

Then **walk the plot a second time** and record all three again. You now have
two independent readings per method per tree.

### What to compute

You probably have no surveyed ground truth, so use **repeatability** as the
measure: the distance between the two readings of the same tree by the same
method. Lower is better, and it needs no reference points.

| Method | Median repeatability | Worst case |
|---|---|---|
| Problem Android | | |
| Good Android | | |
| Watch | | |

If the watch's median is not clearly better than the good Android, the hardware
is not the answer and the problem is software. Check whether TreeMapper uses the
fused location provider rather than raw GNSS, and whether it waits for the fix
to converge, before spending on hardware.

### Also record

- **Time to first fix**, cold, under canopy. This is what the person waits for.
  A brand new watch downloads satellite data on its first outdoor use and can
  take several minutes; that is one-off, do not measure it as typical.
- **Battery over a full session**, receiver running continuously **and the
  stream transmitting**. This is now the most important unknown in the project.
  The old one-shot design was measured against GNSS alone; posting a point every
  second wakes the radio 3,600 times an hour on top of that, and on Android
  every one of those is relayed through Garmin Connect. Measure it at 1 Hz and
  again at 5 s, so there is a real trade to offer field teams rather than a
  guess. Publish the number instead of a specification sheet figure.
- **Whether a dark screen stops anything.** Leave the watch untouched until the
  display sleeps, then check the phone is still receiving. The stream runs off
  its own timer in `SessionState` rather than the view's, specifically so this
  works, but it has never been confirmed on hardware.
- **Two concurrent timers.** The stream timer and the view's render timer run
  at the same time. Most products allow several; confirm yours does not quietly
  drop one.
- **Quality distribution**: how often the fix is `GOOD` versus `USABLE` under
  your canopy. If it sits at `USABLE` all day, the warn-below setting should
  default accordingly.

---

## 3. What the simulator can never tell you

For reference, so nobody re-litigates this:

- Real Bluetooth timing and dropouts. The ADB transport is a TCP socket, so a
  `drop` count of zero there proves nothing about 1 Hz over real Bluetooth.
- Real GNSS. Simulated position comes from a menu.
- Whether `openApplication()` prompts on the wrist.
- The Garmin Connect dependency, which TETHERED bypasses entirely.
- Battery.

The simulator is for protocol and interface work. Everything above needs a
watch on a wrist, outdoors.
