# Watch to phone protocol, version 2

The contract between the TreeMapper GPS watch app and the TreeMapper phone app.
Implement the phone side against this. Nothing here needs the server.

**Version 2 replaced request/response with a stream.** The watch no longer waits
to be asked. It posts its position on a fixed interval, one second by default,
for as long as the app is open and not paused. See "What changed from version 1"
at the bottom if you implemented against the earlier draft.

---

## The constraint that shapes everything

`Position.enableLocationEvents()` is limited to **device apps and widgets**. A
Connect IQ background service can receive a phone message, but it cannot turn
the GNSS receiver on, so it could only ever return a stale cached position.

**Therefore the watch app must be running in the foreground.** The phone cannot
silently pull an accurate coordinate from a sleeping watch. That is a platform
limit, not a design choice.

A cold multi-band fix takes tens of seconds under canopy. So the model is:

> The person opens the watch app when they reach the plot and sets the watch
> down. The receiver stays warm and the position arrives on the phone every
> second, unasked. Nobody presses anything per tree.

The phone can still call `openApplication()` to launch the watch app if it is
not running, but that costs the acquisition wait.

---

## Transport

Connect IQ Mobile SDK, over Bluetooth, via Garmin Connect Mobile.

- **Android**: `ConnectIQ.sendMessage()` / `registerForAppEvents()`
- **iOS**: `ConnectIQ.sharedInstance().sendMessage()` / `registerForAppMessages()`
- **Watch**: `Communications.transmit()` / `Communications.registerForPhoneAppMessages()`

Every message is a **Dictionary** (Map on Android, NSDictionary on iOS).

### The watch cannot speak first

The watch holds everything until the companion app has sent it at least one
message. Transmitting before that is a blind send: on the tethered transport it
raises a modal "no data connection" error in the simulator, and on any transport
it cannot succeed anyway.

**So the stream does not start until the phone says `hello`.** Send it as soon
as the modal opens. Until then the watch shows "Open TreeMapper on phone" and
sends nothing.

### Garmin Connect Mobile: required, but differently on each platform

This is verified against Garmin's own SDK articles. The two platforms are not
the same, which matters for what TreeMapper has to tell the user.

**Android. Hard runtime dependency for everything.**

> "In order for your companion application to communicate with a Connect IQ
> device the user must also install Garmin Connect Mobile onto their phone."
>
> "All communication for companion applications running on Android goes through
> a Garmin Connect Mobile service to reach the device."
>
> "When initializing the SDK with a wireless connection type this requirement is
> checked and initialization will fail if Garmin Connect Mobile is not
> installed."

Passing `true` as the `autoUI` argument to `initialize()` makes the SDK show the
user a prompt to install or upgrade Garmin Connect, with a link to the Play
Store. The demo app does this.

**iOS. Required for discovery and install, not for messaging.**

> "Unlike the Mobile SDK for Android, apps created with the Mobile SDK for iOS
> are standalone apps and do not directly rely on Garmin Connect Mobile (GCM) to
> communicate with a wearable device. They do, however, require GCM to initially
> discover Connect IQ-compatible devices that are available for communication,
> or to install Monkey C applications on the wearable device."

So on iOS, GCM is needed at least once, for the device picker and to install the
watch app, and the two apps hand off through the iOS URL scheme. After that,
messaging is direct Bluetooth and GCM does not have to be running.

**There is no way around it.** A phone cannot reach the watch outside this path:
`Toybox.BluetoothLowEnergy` "provides access to Generic BLE communication
functionality in the central role" only. The watch can scan for and connect to
BLE peripherals; it cannot advertise as one, so a phone cannot connect to it
directly.

---

## Messages

### Phone to watch

| Message | Meaning |
|---|---|
| `{"c":"hello"}` | Identify and ask for current state. Answered with `ready`. **Starts the stream flowing**, because the watch will not transmit before it hears this. |
| `{"c":"ping"}` | Keepalive. Answered with `ready`. |
| `{"c":"rate","ms":<Number>}` | Change the stream interval. Clamped to 500 to 60000 ms. Answered with `ready` carrying the interval actually adopted. |

There is no `fix` command. With a point arriving every second there is nothing
to request: the phone already has one that is at most one interval old.

### Watch to phone

**`pt`** — a point. This is the bulk of the traffic.

```json
{"t":"pt","sid":1792416000,"n":48,
 "lat":"12.3456789","lon":"77.1234567","alt":812.4,
 "q":4,"ts":1792416345,"spd":0.2}
```

| Field | Type | Meaning |
|---|---|---|
| `sid` | Number | Session id. Epoch seconds at app start. Changes on every restart. |
| `n` | Number | Sequence within the session, from 1. Counts points handed to the radio. |
| `lat`, `lon` | **String or Double** | Degrees. See the precision warning below. |
| `alt` | Float | Metres above mean sea level. Absent when the receiver has none. |
| `q` | Number | `Position.Quality`, 0 to 4. |
| `ts` | Number | **GPS** epoch seconds of the fix, not the watch clock. |
| `spd` | Float | Metres per second. Absent when the receiver has none. Useful for telling a standing user from a walking one. |

**`ready`** — state. Sent on start, in answer to `hello`, `ping` or `rate`, and
as a heartbeat every 5 seconds whenever no points are flowing (paused, or no fix
yet). While points *are* flowing they are the heartbeat, and `ready` goes quiet.

```json
{"t":"ready","v":2,"sid":1792416000,"q":3,"gps":1,"mb":1,
 "st":"live","ms":1000,"n":412,"drop":3}
```

| Field | Meaning |
|---|---|
| `v` | Protocol version. Currently 2. |
| `sid` | Session id, same value as on every `pt` of this session. |
| `q` | Current fix quality, 0 to 4. |
| `gps` | 1 when the receiver is running. |
| `mb` | 1 when this device gave a multi-band (L1 + L5) solution. |
| `st` | `"live"` or `"paused"`. Paused is the user's choice on the watch. |
| `ms` | Current stream interval in milliseconds. |
| `n` | Points handed to the radio so far this session. |
| `drop` | Points lost **while the link was up**: the radio was still busy, or the transmit was refused. See below. |

There is no `err` message. The only error version 1 could report was
`no_position`, which was an answer to a request. A stream has nothing to answer:
when there is no position, no point is sent, and `gps` and `q` in the heartbeat
say why.

---

## Reading `drop`

`drop` counts only points lost while the phone was in range and the companion
app was listening. It does **not** count the time the watch spent with no phone
nearby, which would run into the thousands over one lunch break and bury the
signal.

So `drop` means one thing: **this interval is too fast for this link.** A `drop`
climbing steadily against a healthy `n` is the cue to send
`{"c":"rate","ms":2000}`. A `drop` of zero or near zero means 1 Hz is holding.

---

## Three rules worth stating plainly

### Nothing is acknowledged, and nothing is retried

Version 1 held one fix until the phone acknowledged it. A stream cannot: by the
time a retry went out, the coordinate would be stale and a fresher one would
already be waiting. So a point that does not make it is dropped and counted.

What replaces the delivery guarantee is **liveness**. The watch screen shows how
long ago the phone last took anything, so a dead link is visible on the wrist
rather than discovered at the end of the day. The phone should do the same in
its own interface.

### The watch never filters on quality

Every point goes out with `q` attached, whatever it is. **The phone owns the
policy** on what is good enough to keep, and with a point every second it has
plenty to choose from.

| `q` | Constant | Meaning |
|---|---|---|
| 0 | `QUALITY_NOT_AVAILABLE` | no fix |
| 1 | `QUALITY_LAST_KNOWN` | stale cached position |
| 2 | `QUALITY_POOR` | 2D fix, few satellites |
| 3 | `QUALITY_USABLE` | 3D fix, marginal precision |
| 4 | `QUALITY_GOOD` | 3D fix, good precision |

There is **no metric accuracy**. Connect IQ reports this enum and nothing else,
unlike Android which gives metres. Store `q` as its own column and flag the
point's source, per `DESIGN.md` section 9.

### Coordinates may arrive as Strings

`source/GpsService.mc` has `const SAFE_COORDS = true`, which formats `lat` and
`lon` with `"%.7f"` and sends them as **Strings**. Seven decimals is about 1 cm,
far finer than any GNSS fix, and it keeps 64-bit Doubles off the wire where they
are the prime suspect for serialisation crashes once nulls are ruled out.

Set `SAFE_COORDS = false` to send real Doubles instead.

**The phone must accept both.** Parse a String with a double parser, never a
float one: a 32-bit float carries about 7 significant digits, which is not
enough for `12.3456789`. This is the easiest thing to get wrong here and the
hardest to notice, because the data looks plausible and is quietly wrong by
metres.

---

## Optional fields are absent, not null

`alt` and `spd` are omitted entirely when they have no value, rather than sent
as null. Read a missing key as null on the phone.

This is not cosmetic. A Dictionary carrying null values has to be serialised
into a Java `Map` across the link, and that path is a prime suspect for
simulator crashes on transmit. The watch strips nulls before every send.

---

## Deduplication and session identity

Key a point on **`(sid, n)`**.

- `sid` is epoch seconds at app start, so it changes on every restart. Two
  points with the same `n` and different `sid` are different points.
- `n` counts points handed to the radio, so **a gap in `n` means a point was
  lost in transit**, not that the watch skipped one. That is a useful signal:
  gaps and `drop` should roughly agree.
- Neither is durable beyond the session. Pair them with your own arrival
  timestamp if you need a stable key in storage.

Duplicates are unlikely now that nothing is retried, but dedupe anyway: the
Android SDK is reported to fire both SUCCESS and FAILURE_UNKNOWN for one send on
the tethered transport.

---

## What the phone does with the stream

The agreed model is that **the user decides**. The watch sends coordinates and
their quality; TreeMapper shows the live position and its quality in the
capture interface, and the person chooses whether to record it against the tree
in front of them. The watch imposes no policy and the phone stores nothing it
was not asked to.

```
user opens the TreeMapper capture screen
  → ConnectIQ.initialize(), wait for onSdkReady
  → getConnectedDevices()
       none? "No Garmin watch paired" and stop
  → getApplicationInfo(APP_UUID)
       not installed? openStore(APP_UUID)
  → registerForAppEvents()
  → sendMessage({"c":"hello"})            <- the stream starts here

       pt arrives, and keeps arriving every second
         → show lat/lon and the quality word live
         → user taps "use this position" when it looks right

       ready arrives with gps=0, or nothing arrives in ~2s
         → openApplication()
         → show "starting watch receiver", keep polling with ping
         → show live q from each ready message

       ready arrives with st="paused"
         → say so plainly: the user paused it on the watch, and only the
           watch can resume it
```

Three states worth designing for, because they are the ones that happen in the
field:

- **Watch app not running.** `openApplication()` then a wait that can run to a
  minute. Show the live quality from `ready` so the wait is legible.
- **Paused on the watch.** The phone cannot resume it. Say who can.
- **Quality below 3.** Do not block. Show the warning and let the person decide,
  since they may be under canopy where 3 is the best available all day.

### Two things worth building, later

Neither is in scope now, but the stream makes both possible and the data model
should not rule them out:

- **Averaging.** A single GNSS fix is the weakest thing you can record. Fifteen
  fixes taken while somebody stands still at a tree, averaged, beat any one of
  them. This is the strongest accuracy argument the project has, and it only
  exists because the position arrives continuously.
- **Track recording.** The same stream is a walking track for plot boundaries
  and audit, if anyone wants one.

---

## If the simulator crashes when the watch transmits

**Most likely cause: the phone is not listening, and cannot be.** Over the
tethered (ADB) transport the Connect IQ simulator stamps outbound messages with
an **empty application id** instead of the one in `manifest.xml`. The Android
SDK routes by that id, so `registerForAppEvents(device, IQApp(<real id>))` is
never called. The watch transmits, is never acknowledged, retries into a socket
nobody reads, and the simulator dies with `Socket Error in packet header 0`.

The fix is one line on the phone: register a second listener for `IQApp("")`.
The demo app does this in `WatchLink.listenForMessages()`. The same transport
also reports `getApplicationInfo()` as `UNKNOWN` for an app that is running, so
never gate the listener on it.

Reported at
<https://forums.garmin.com/developer/connect-iq/f/discussion/379720/android-mobile-sdk---tethered-connection---app-status-unknown>.

Nothing in the watch code causes this and nothing in the watch code can fix it.

If it still crashes after that, bisect by payload. `ready` carries no Doubles
and no nulls; `pt` carries coordinates. If `ready` arrives and `pt` kills it,
the problem is in the point payload, and `SAFE_COORDS` is the switch to try. If
`ready` kills it too, the transport itself is the problem and the next step is a
real watch.

Two structural rules the watch already follows, both worth keeping if you
rewrite this:

1. **Never transmit from inside the receive callback.** Sending from within
   `onPhoneMessage` re-enters the comms stack. Commands set a flag and the next
   stream tick does the work.
2. **Never transmit from `AppBase.onStart`.** Too early; no view, no settled
   link. The first stream tick sends the opening `ready`.

---

## Testing without a watch

The Android SDK has a simulator transport:

```
ConnectIQ.getInstance(IQCommProtocol.ADB_SIMULATOR)   // port 7381
adb forward tcp:7381 tcp:7381
```

Then *Connection > Start* (Ctrl-F1) in the Connect IQ simulator. It throttles to
real Bluetooth speeds, which makes it the right place to find out whether 1 Hz
actually holds, and to watch `drop` climb if it does not.

---

## What changed from version 1

| | v1 | v2 |
|---|---|---|
| Model | one fix per request, acknowledged | continuous stream, fire and forget |
| Phone commands | `hello`, `ping`, `fix` | `hello`, `ping`, `rate` |
| Watch messages | `ready`, `pt`, `err` | `ready`, `pt` |
| `pt` fields | had `r`, `src` | dropped both; added `sid` |
| `ready` fields | had `buf` (always 0) | dropped it; added `sid`, `st`, `ms`, `n`, `drop` |
| Delivery | held until acknowledged | dropped and counted |
| Session identity | `n` only, not durable | `(sid, n)` |

No phone client shipped against version 1, so there is no compatibility path and
the watch does not answer v1 commands.
