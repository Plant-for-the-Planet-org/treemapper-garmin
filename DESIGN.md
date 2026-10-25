# TreeMapper Garmin Integration: Technical Design

**Status:** Draft for review
**Date:** 20 September 2026
**Author:** Shyam Bhongle, Plant-for-the-Planet
**Platform reference:** `docs-research/` in this repo (Connect IQ SDK 9.2.0)

---

> ### Amendment, 1 October 2026: the offline buffer was removed
>
> This document is kept as the original design record. One decision in it has
> since been reversed, and the text below has **not** been rewritten to match.
>
> **The watch no longer stores anything.** There is no offline buffer, no
> session record and no tree count. One fix exists at a time, in memory, from
> the moment the user asks to send it until the phone acknowledges it. A send
> that fails is reported on screen and the user chooses: retry the same fix, or
> start over and take a new one. To record another tree the flow runs again
> from acquisition.
>
> What this changes against the text below:
>
> - Section 4: "Buffer points locally when the phone is out of range, flush on
>   reconnect" no longer applies.
> - Section 9's offline buffer is not built.
> - The `buffer_full` / `queue_full` error is retired.
> - The watch UI mock in section 9 showing a session count is superseded.
>
> The working contract is **`PROTOCOL.md`**, which is current. Where the two
> disagree, PROTOCOL.md wins.
>
> **The trade accepted:** a fix taken out of Bluetooth range is not kept. The
> person has to be in range to record a tree, and the watch says so plainly.
> In exchange the watch holds no state that can go stale, be half-delivered, or
> be lost silently, and the phone remains the single owner of the record.

---

> ### Amendment, 25 October 2026: the link became a stream
>
> The second reversal, and the larger one. Where the amendment above changed
> what the watch keeps, this changes what the watch is for.
>
> **The watch no longer waits to be asked.** From the moment TreeMapper has
> said hello, it posts its position on a fixed interval, one second by default,
> until it is paused from the wrist or the app is closed. There is no per-tree
> press on the watch and no request from the phone. The person opens the app at
> the plot, sets the watch down, and works entirely from TreeMapper.
>
> **Why.** The one-shot flow asked the user to operate two devices at every
> tree. Streaming removes the watch from the loop: the phone always holds a
> position that is at most one interval old, so recording a tree is a phone
> action again, as it was before any of this existed.
>
> What this changes against the text below:
>
> - Section 4: the watch no longer reads a position "on button press", and it
>   does **not** "reject any fix below QUALITY_USABLE". It filters nothing. The
>   quality setting on the watch only colours its own screen.
> - Section 5's protocol is superseded entirely. `start`, `stop`, `flush` and
>   `fix` are gone; `rate` is new. `err` is gone. `pt` lost `r` and `o` and
>   gained `sid`. See `PROTOCOL.md`.
> - Section 6's `capture()` sketch, its quality floor and its vibration calls
>   do not reflect the code. There are no haptics at all.
> - Section 6's screen mock is superseded by the stream screen.
> - Section 10's error table assumes buffering and a quality floor; neither
>   exists. A point that cannot be sent is dropped and counted.
> - Section 12's unit test list should read: sequence numbering, interval
>   clamping, drop accounting, and the serialisation of coordinates.
>
> **Two things this gives up.** There is no per-point delivery guarantee any
> more: a stream cannot wait for an acknowledgement, because a retry would put
> a stale coordinate on the wire. What replaces it is liveness, shown on both
> screens. And the battery cost is higher and currently **unmeasured**, which
> is the single most important open item in this document. The watch accepts a
> `rate` command specifically so the interval can be widened after measurement
> without shipping a new build.
>
> **One thing it makes possible, not yet built.** A continuous position stream
> means the phone can average many fixes taken while somebody stands still at a
> tree. That beats any single fix, and it is a stronger accuracy argument than
> section 1 makes. The agreed v1 behaviour is simpler: the phone shows the live
> position and its quality, and the user decides whether to record it.
>
> The working contract is **`PROTOCOL.md`**, which is current. Where this
> document and PROTOCOL.md disagree, PROTOCOL.md wins. Where the two amendments
> disagree, the later one wins.

---

## 1. Problem

TreeMapper (Android and iOS) geotags trees, records measurements, and uploads to the ForestCloud server. On some Android devices the GPS fix is not accurate enough for the plots we map, especially under canopy where multipath and signal blockage are worst.

Garmin watches with multi-band GNSS (GPS L1 + L5, plus GLONASS, Galileo and BeiDou) resolve multipath far better than a single-band phone chipset. The goal is to use the watch as the position source while keeping every other part of TreeMapper unchanged.

### Non-goals

- Replacing TreeMapper's data entry on the watch
- Recording activities or FIT files
- Supporting watches the organisation has not purchased
- Any change to the upload pipeline or server auth

---

## 2. Decision

**Build a thin Connect IQ watch app that acts as a GPS sensor for the existing TreeMapper phone app.**

The watch captures a fix and hands it to TreeMapper over Bluetooth. TreeMapper keeps species selection, measurements, photos, the offline queue, auth and upload exactly as they are today. The server never learns the watch exists.

### Options considered

| Option | Verdict |
|---|---|
| **A. Standalone watch app** that captures points, stores them, and uploads to ForestCloud itself | **Rejected.** Data entry on a 260 px round screen is unusable for species and measurements. `Application.Storage` caps at 128 KB total per app, roughly 1000 bare coordinate records. Would need its own OAuth flow and a second server client, for no gain. |
| **B. Watch as a sensor, phone as the brain** | **Chosen.** Smallest watch app, zero server change, reuses all existing TreeMapper logic. The Connect IQ Mobile SDK gives direct Bluetooth messaging between our phone app and our watch app, with no Garmin cloud in the path. |
| **C. Watch writes a FIT file, phone imports it after the session** | **Rejected for v1.** Adds the `Fit` permission, moves the app into the device Activities list instead of the apps list, and gives no live feedback at the tree. Worth revisiting only if we later want a continuous walking track. |

---

## 3. System overview

```
┌──────────────────────┐        BLE         ┌──────────────────────┐
│  Garmin watch        │◄──────────────────►│  Phone               │
│                      │  via Garmin        │                      │
│  TreeMapper GPS      │  Connect Mobile    │  TreeMapper app      │
│  (Connect IQ         │                    │  + Connect IQ        │
│   watch-app)         │                    │    Mobile SDK        │
│                      │                    │                      │
│  • multi-band GNSS   │                    │  • species, DBH,     │
│  • quality filter    │                    │    height, photos    │
│  • offline buffer    │                    │  • offline queue     │
│  • capture button    │                    │  • auth + upload     │
└──────────────────────┘                    └──────────┬───────────┘
                                                       │ HTTPS
                                                       ▼
                                            ┌──────────────────────┐
                                            │  ForestCloud server  │
                                            │  (unchanged)         │
                                            └──────────────────────┘
```

### Hard prerequisite

The Connect IQ Mobile SDK routes all watch traffic through the **Garmin Connect Mobile** app. The user must have Garmin Connect Mobile installed, signed in, and the watch paired to it. TreeMapper must detect this and guide the user, because a silent failure here looks like "the watch does not work".

---

## 4. Responsibilities

### Watch app (`treemapper-gps`)

- Manage the GNSS receiver: enable at session start, keep warm, disable at session end
- Read `Position.getInfo()` on demand or on button press
- Reject any fix below `QUALITY_USABLE`
- Show live fix quality so the user knows when it is safe to capture
- Send accepted points to the phone
- ~~Buffer points locally when the phone is out of range, flush on reconnect~~
  (removed, see the amendment at the top)
- Nothing else. No species, no measurements, no server calls.

### Phone app (TreeMapper)

- Discover the watch, check the app is installed, launch it remotely
- Drive the session lifecycle
- Receive points, deduplicate by session and sequence number
- Create a draft tree record from each point, then let the user fill in the rest as today
- Fall back to phone GPS when no watch is connected
- Surface connection state clearly in the UI

---

## 5. Message protocol

Connect IQ `Communications.transmit()` accepts primitives, Strings, Arrays, Dictionaries and byte arrays. The Android SDK maps Java `int / long / float / double / boolean / char / String / List / Map`; iOS maps `NSString / NSNumber / NSArray / NSDictionary / NSNull`. A Dictionary with short keys is the right shape.

### Critical: use Double for coordinates

`Position.Location.toDegrees()` returns `[Double, Double]`. A 32-bit Float carries about 7 significant digits, which is not enough for a latitude such as `12.3456789`. **Send latitude and longitude as Double, never Float.** Verify the phone side deserialises them as `double` and not `float`.

### Phone to watch

| Message | Purpose |
|---|---|
| `{"c":"start","s":<sessionId:Long>,"q":<minQuality:Number>}` | Begin a mapping session, enable GNSS, set the quality floor |
| `{"c":"fix","r":<reqId:Number>}` | Request one point now |
| `{"c":"flush"}` | Ask the watch to resend anything buffered |
| `{"c":"stop"}` | End session, disable GNSS |

### Watch to phone

| Message | Purpose |
|---|---|
| `{"t":"pt","s":<sessionId>,"n":<seq>,"r":<reqId or null>,"lat":<Double>,"lon":<Double>,"alt":<Float>,"q":<0..4>,"ts":<epochSeconds>,"o":"btn"\|"req"}` | An accepted point. `o` says whether the user pressed the watch button or the phone asked. |
| `{"t":"st","gps":<0\|1>,"q":<0..4>,"bat":<Number>,"buf":<Number>}` | Status heartbeat: GNSS on, current quality, battery percent, buffered point count |
| `{"t":"err","code":"<string>"}` | `no_fix`, `low_quality`, `gps_denied`, `buffer_full` |

### Deduplication

Every point carries `s` (session id, assigned by the phone) and `n` (monotonic sequence, assigned by the watch). The phone ignores any `(s, n)` pair it has already stored. This makes `flush` safe to call repeatedly and makes reconnects idempotent.

---

## 6. Watch app design

### Manifest

```xml
<iq:application
    id="<generate with Monkey C: Regenerate UUID>"
    type="watch-app"
    name="@Strings.AppName"
    launcherIcon="@Drawables.LauncherIcon"
    minApiLevel="3.3.6">

  <iq:products>
    <!-- exactly the purchased models, nothing else -->
  </iq:products>

  <iq:permissions>
    <iq:uses-permission id="Positioning"/>
    <iq:uses-permission id="Communications"/>
  </iq:permissions>
</iq:application>
```

Notes:
- Type must be `watch-app`. Only widgets and device apps may call `Position.enableLocationEvents()`. A watch face or data field cannot do this.
- `minApiLevel` 3.3.6 because the multi-band GNSS configuration constants arrived there.
- Two permissions only. Every extra permission is shown to the user before install and costs conversion.
- No `Background` permission in v1. Everything happens in the foreground.

### GNSS configuration

Request the best supported mode, and always gate with `hasConfigurationSupport()` so one binary runs on every purchased model:

```monkeyc
function bestConfig() as Position.ConfigurationType {
    var preferred = [
        Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5,  // multi-band, best accuracy
        Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1,
        Position.CONFIGURATION_GPS_GALILEO,
        Position.CONFIGURATION_GPS
    ];
    for (var i = 0; i < preferred.size(); i++) {
        if (Position.hasConfigurationSupport(preferred[i])) {
            return preferred[i];
        }
    }
    return Position.CONFIGURATION_GPS;
}

function startGps() as Void {
    Position.enableLocationEvents({
        :acquisitionType => Position.LOCATION_CONTINUOUS,
        :configuration   => bestConfig()
    }, method(:onPosition));
}
```

Do **not** use `CONFIGURATION_SAT_IQ`. It trades accuracy for battery by picking the solution dynamically, which is the opposite of what we want.

### Turning GPS off

Connect IQ does not stop the receiver on its own. Call it explicitly on session stop, on `onStop()`, and on any unrecoverable error:

```monkeyc
Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
```

Missing this is the number one cause of battery complaints.

### Quality filtering

`Position.Info.accuracy` is an enum, not a value in metres:

| Constant | Value | Meaning |
|---|---|---|
| `QUALITY_NOT_AVAILABLE` | 0 | no fix |
| `QUALITY_LAST_KNOWN` | 1 | stale cached position |
| `QUALITY_POOR` | 2 | 2D fix, few satellites |
| `QUALITY_USABLE` | 3 | 3D fix, marginal precision |
| `QUALITY_GOOD` | 4 | 3D fix, good precision |

Per the decision taken, the watch filters and the phone stores the enum. Default floor is `QUALITY_USABLE` (3), configurable from the phone via the `q` field on `start` so field teams can raise it to 4 for research plots.

**Positions are dead reckoned between fixes.** The docs state that `position` is interpolated between real fixes and then stops propagating. Always send `ts` (the GPS timestamp from `Position.Info.when`, not the watch clock) with every point, and have the phone reject any point whose `ts` is more than a few seconds old.

```monkeyc
function capture(reqId as Number or Null, origin as String) as Void {
    var info = Position.getInfo();

    if (info.accuracy < _minQuality || info.position == null) {
        transmit({ "t" => "err", "code" => "low_quality" });
        Attention.vibrate([new Attention.VibeProfile(50, 200)]);  // one short buzz = rejected
        return;
    }

    var deg = info.position.toDegrees();   // [Double, Double]
    _seq++;

    var point = {
        "t"   => "pt",
        "s"   => _sessionId,
        "n"   => _seq,
        "r"   => reqId,
        "lat" => deg[0],
        "lon" => deg[1],
        "alt" => info.altitude,
        "q"   => info.accuracy,
        "ts"  => info.when.value(),
        "o"   => origin
    };

    if (_phoneConnected) {
        transmit(point);
    } else {
        bufferPoint(point);
    }
    Attention.vibrate([new Attention.VibeProfile(75, 400)]);  // one long buzz = captured
}
```

### Offline buffer

`Application.Storage` gives 8 KB per key and 128 KB per app, and needs no permission.

- Serialise points into chunks, roughly 50 points per key to stay well under 8 KB
- Keys: `buf_0`, `buf_1`, and so on, plus a `buf_meta` dictionary holding the head and tail index
- Cap at around 1000 points, then send `buffer_full` and refuse further captures rather than silently dropping
- On reconnect, or on `flush`, send chunks oldest first and delete each key only after the phone acknowledges

For a normal working day with the phone in a pocket this buffer will rarely be used. It exists so a dropped Bluetooth link does not lose a morning's work.

### Screen

One view, no menus. Large and readable with gloves on, in sunlight:

```
   ┌─────────────────────┐
   │   GNSS  ████████░░  │   quality bar, colour coded
   │      GOOD           │   red / amber / green
   │                     │
   │       47            │   points captured this session
   │     points          │
   │                     │
   │   ● phone linked    │   or "● buffering (12)"
   │                     │
   │   [ START to save ] │
   └─────────────────────┘
```

Bind capture to the START/SELECT button through `BehaviorDelegate.onSelect()`, not `onKey()`, so the same code works on touch and button devices. Redraw once per second with a `Timer`; do not redraw on every position event.

**Feedback matters more than the screen.** The user will often be looking at the tree, not the watch. One long buzz means saved, one short buzz means rejected. Consider a distinct double buzz when quality drops below the floor so the user knows to wait.

---

## 7. Android integration

```gradle
implementation "com.garmin.connectiq:ciq-companion-app-sdk:<latest>@aar"
```

```java
ConnectIQ ciq = ConnectIQ.getInstance(context, ConnectIQ.IQConnectType.WIRELESS);

ciq.initialize(context, true, new ConnectIQListener() {
    @Override public void onSdkReady() {
        // only now is any other call legal
        List<IQDevice> devices = ciq.getConnectedDevices();
        ciq.registerForDeviceEvents(device, deviceEventListener);
    }
    @Override public void onInitializeError(IQSdkErrorStatus status) {
        // most likely Garmin Connect Mobile missing or too old
    }
    @Override public void onSdkShutDown() { }
});
```

Then:

```java
IQApp app = new IQApp(WATCH_APP_UUID);

ciq.getApplicationInfo(WATCH_APP_UUID, device, new IQApplicationInfoListener() {
    @Override public void onApplicationInfoReceived(IQApp app) {
        ciq.openApplication(device, app, openListener);   // launch it remotely
    }
    @Override public void onApplicationNotInstalled(String uuid) {
        ciq.openStore(uuid);   // send the user to the Connect IQ store
    }
});

ciq.registerForAppEvents(device, app, (d, a, messageData, status) -> {
    // messageData is a List<Object>; first element is our Map
});

ciq.sendMessage(device, app, payloadMap, sendListener);
```

Points to watch:
- `onSdkReady()` must fire before anything else. Calling early throws.
- Android 12 and above need `BLUETOOTH_CONNECT` at runtime even though the link is via Garmin Connect Mobile.
- Device events are `CONNECTED`, `NOT_CONNECTED`, `NOT_PAIRED`. Map each to a distinct UI state; "not paired" needs different guidance from "not connected".
- Wrap `initialize()` failure with a clear message naming Garmin Connect Mobile.

---

## 8. iOS integration

Install via Swift Package Manager from the Garmin GitHub repo, embed as a binary framework, add the `-ObjC` linker flag.

`Info.plist` needs: a URL scheme, `NSBluetoothAlwaysUsageDescription`, and a bundle display name.

```swift
ConnectIQ.sharedInstance().initialize(urlScheme: "treemapper-ciq",
                                      uiOverrideDelegate: self)

// device selection hands off to Garmin Connect and returns via the URL scheme
ConnectIQ.sharedInstance().showConnectIQDeviceSelection()

let app = IQApp(uuid: UUID(uuidString: WATCH_APP_UUID), device: device)
ConnectIQ.sharedInstance().registerForAppMessages(app, delegate: self)
ConnectIQ.sharedInstance().sendMessage(payload, toApp: app,
                                       progress: { _, _ in },
                                       completion: { result in })
```

The iOS device selection flow leaves TreeMapper, opens Garmin Connect, and returns through the URL scheme. Handle the case where the user cancels or Garmin Connect is not installed.

**iOS is materially more fiddly than Android here.** Plan it as a separate phase, not as a same-sprint port.

---

## 9. Data model

Add to the tree record, on the client and in the upload payload:

| Field | Type | Notes |
|---|---|---|
| `location_source` | enum | `phone` or `garmin`. Lets analysts filter and compare. |
| `gnss_quality` | int, nullable | 0 to 4 for garmin points. Null for phone points. |
| `accuracy_m` | float, nullable | Existing field. Null for garmin points. |
| `gnss_device` | string, nullable | Watch model, for example `fenix8` |
| `fix_timestamp` | timestamp | GPS time from the watch, distinct from the phone clock |

### The two-scale problem, stated plainly

Phone points carry accuracy in metres. Watch points carry a 0 to 4 enum. These are not comparable, and no honest conversion exists. Because the watch filters at `QUALITY_USABLE` or better, every garmin point has an implicit quality floor, but we cannot state a metre figure for it.

Mitigation: `location_source` makes the two populations separable at query time. Anyone doing analysis must group by it rather than mixing the columns. This should be written into the data dictionary, not left as tribal knowledge.

If a metre figure later turns out to be required for reporting, the fallback is to derive an empirical mapping from the phase 0 field test (see below) and store it as a separate `accuracy_m_estimated` column, clearly named so no one mistakes it for a measurement.

---

## 10. Error handling

| Situation | Behaviour |
|---|---|
| Garmin Connect Mobile not installed | Block the watch feature, explain, link to the store. Fall back to phone GPS. |
| Watch app not installed | `openStore(uuid)` |
| Watch not connected mid-session | Watch buffers, phone shows "watch offline, buffering". On reconnect, phone sends `flush`. |
| Quality below floor at capture | Watch buzzes short, sends `low_quality`, saves nothing. Phone shows a transient toast. |
| No fix at all after 90 seconds | Watch shows "no signal", phone offers to fall back to phone GPS for that point, tagged `location_source: phone`. |
| Watch battery below 15 percent | Status heartbeat carries it; phone warns once. |
| User closes the watch app mid-session | Phone detects the app event stream stopping, offers to relaunch via `openApplication()`. |

The fallback to phone GPS must always be available. A field team must never be blocked because a watch died.

---

## 11. Battery

Continuous multi-band GNSS is the heaviest thing a Garmin watch does. Expect roughly a full working day on a fēnix-class device, less on a smaller case size. Practical measures:

- Enable GNSS at session start, not at app start
- Always disable on session stop
- Redraw the screen once per second, not on every position callback
- Do not add `ActivityRecording` in v1; a recording session adds its own drain
- Tell field teams to start the session when they reach the plot, not at the vehicle

Measure real drain during phase 0 and publish the number to field teams. A stated "about 8 hours of mapping" is worth more than a specification sheet figure.

---

## 12. Testing

**Simulator.** The Connect IQ simulator plays back position data and simulates GNSS quality. This covers the state machine and the quality filter.

**ADB bridge.** The Android SDK has a simulator transport: `getInstance(IQCommProtocol.ADB_SIMULATOR)`, default port 7381, then `adb forward tcp:7381 tcp:7381` and *Connection > Start* (Ctrl-F1) in the simulator. It deliberately throttles to real Bluetooth speeds, so it is the right place to test the protocol and the reconnect path without a physical watch.

**Unit tests.** Run No Evil (`(:test)` annotation) runs in the simulator only. Cover the quality filter, sequence numbering, buffer chunking and the serialisation of Double coordinates.

**Field test.** See phase 0.

**Memory.** Keep the simulator's File > View Memory open. This app should sit far below any device limit, but watch the buffer serialisation, which is where growth will come from.

---

## 13. Distribution

TreeMapper is already public on both app stores, so the watch app goes to the **Connect IQ Store** as a public listing. This avoids the platform's worst limitation: Connect IQ has no private or enterprise channel, and beta builds install only on the developer's own account.

Required:
- Developer account, and an RSA 4096 developer key. **Back the key up in the org password manager.** Lose it and the app can never be updated.
- Store icon 500 x 500 px under 300 KB, launcher icon 128 x 128 px, hero image 1440 x 720 px, screenshots under 150 KB each
- A description that states plainly the app is a companion to TreeMapper and does nothing on its own
- A privacy policy, because the app handles location. The Developer Agreement requires that location collection is opt-in and not on by default, which our session model already satisfies.

Review timelines are not published. Forum reports suggest days to two weeks for a first submission. Plan for it.

During development, sideload the `.prg` over USB to the test watches.

---

## 14. Phased plan

**Phase 0: validate the premise (1 week, before writing app code)**

Buy two watches. Walk a known plot with: the current TreeMapper on the problem Android device, the same on a good Android device, and one watch. Capture the same 30 tree positions three ways. Compare spread against a surveyed reference if one exists, or against repeatability if not.

Also check whether TreeMapper's Android GPS code is the real culprit. If it uses the fused location provider rather than raw GNSS, or does not wait for convergence, fixing that helps every user and may reduce how many watches are needed.

Exit criterion: a measured accuracy gain that justifies the hardware spend.

**Phase 1: watch app plus Android (3 to 4 weeks)**

Watch app, protocol, Android integration, phone-initiated and button-initiated capture, offline buffer. Sideloaded, not published.

**Phase 2: field pilot (2 weeks)**

One team, real plots, real weather. Measure battery, connection drops, and capture rate. Expect the findings to be about ergonomics rather than code.

**Phase 3: iOS (2 weeks)**

**Phase 4: Connect IQ Store submission**

---

## 15. Open questions

1. **Which models exactly?** Standardise on one or at most two, to keep the test matrix small. Verify multi-band support against the Connect IQ device reference and confirm at runtime with `Position.hasConfigurationSupport()`. Do not trust marketing pages.
2. **Who owns the Garmin developer account?** It should be an organisational account, not a personal one, and the developer key belongs in the org password manager.
3. **Does the analysis pipeline need a metre figure?** If yes, decide in phase 0 how to derive it. If no, `gnss_quality` plus `location_source` is enough and simpler.
4. **Do field teams already carry a phone?** The whole design assumes yes. If some teams carry only a watch, option A comes back into scope and the calculation changes completely.
5. **Multiple watches per phone?** The SDK supports several paired devices. v1 should pick one and say so.

---

## Appendix: platform facts this design depends on

All from `docs-research/` in this repo.

- `Position.enableLocationEvents()` is available only to `widget` and `watch-app` types
- `Position.Info.accuracy` is a 0 to 4 enum, never metres
- Positions are dead reckoned between real fixes, then freeze
- GNSS does not switch itself off
- `Application.Storage`: 8 KB per key, 128 KB per app, no permission needed
- `Communications` permission is required for phone messaging; on a watch face or data field it would also need `Background`, but not for a `watch-app`
- Background temporal events fire at most every 5 minutes and return about 8 KB, which is why sync stays in the foreground
- Debugging works in the simulator only
- There is no private or enterprise distribution channel for Connect IQ
