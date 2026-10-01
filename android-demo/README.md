# TreeMapper Watch Test

A bench harness for the Garmin link. Not the TreeMapper modal: it exposes every
step of the handshake separately, so when something fails you can tell **which**
step failed rather than staring at a spinner.

Protocol lives in [`../PROTOCOL.md`](../PROTOCOL.md). `Protocol.kt` mirrors it.

---

## Two transports, and only one of them needs Garmin Connect

The switch at the top of the app picks between them.

| | **Real watch** (WIRELESS) | **Simulator** (TETHERED) |
|---|---|---|
| Garmin Connect Mobile | **Required** | **Not needed at all** |
| Watch paired in Garmin Connect | Required | n/a |
| Transport | Bluetooth, proxied by Garmin Connect | TCP socket over `adb forward` |
| Works on an emulator | No | Yes |

Garmin's Android SDK article is explicit, verbatim:

> "In order for your companion application to communicate with a Connect IQ
> device the user must also install Garmin Connect Mobile onto their phone."
>
> "All communication for companion applications running on Android goes through
> a Garmin Connect Mobile service to reach the device."
>
> "When initializing the SDK with a wireless connection type this requirement is
> checked and initialization will fail if Garmin Connect Mobile is not
> installed."

So on Android it is a hard runtime dependency, not just for setup. Pairing in
Android's own Bluetooth settings does not help, because Garmin Connect holds the
pairing. This app passes `autoUI = true` to `initialize()`, which makes the SDK
prompt the user to install or upgrade it.

**iOS is different**, worth knowing before the iOS work starts: there, GCM is
required to discover devices and to install the watch app, but messaging itself
is direct Bluetooth and does not go through it. See `../PROTOCOL.md`.

TETHERED sidesteps all of it. That is the whole point of the mode: it exists so
you can develop without hardware.

Either way you also need **the watch app itself**: built and running in the
Connect IQ simulator, or sideloaded to a real device by copying the `.prg` into
`GARMIN/APPS`.

---

## Running against the simulator, in this exact order

Order matters. The Android app opens the socket and the Connect IQ simulator
dials into it, so if the app is not up and in TETHERED mode first, the simulator
reports "There is no data connection" and then "ADB Disconnected".

1. Start the Android emulator. Confirm with `adb devices`.
2. Install and launch this app on the emulator.
3. **Turn the "ADB simulator" switch ON.** The log should say
   `initialising SDK in TETHERED mode`. This is the step most people miss: in
   WIRELESS mode the app never opens port 7381, so nothing can connect to it.
4. In a terminal: `adb forward tcp:7381 tcp:7381`
5. Build and run the watch app into the Connect IQ simulator, so a watch app is
   actually live and listening for messages.
6. In the simulator menu: **Connection > Start**.

The app's log will show the SDK becoming ready and a device appearing.

### Using a real phone instead of the emulator

The ADB transport does not care what kind of device it is. A physical phone over
USB works exactly the same, and is the better choice: real CPU, real Bluetooth
stack scheduling, real app lifecycle when you background it.

1. Enable Developer options and USB debugging on the phone, plug it in, and
   accept the debugging prompt.
2. `adb devices` should list it.
3. Same steps as above. Still no Garmin Connect needed: in TETHERED mode the
   phone never touches Bluetooth.

**If both an emulator and a phone are attached, `adb forward` fails with
"more than one device".** Name the one you want:

```bash
adb devices                                   # copy the serial
adb -s <serial> forward tcp:7381 tcp:7381
```

Wireless debugging works too, so you can test without a cable:

```bash
adb pair <phone-ip>:<pairing-port>            # once, from the phone's screen
adb connect <phone-ip>:<port>
adb -s <phone-ip>:<port> forward tcp:7381 tcp:7381
```

### What this setup still does not prove

The phone is real but the watch is not, so everything watch-side is simulated:

- **Real Bluetooth.** The link is a TCP socket. Latency and dropouts will not
  behave like BLE in a forest, though the transport does throttle to roughly
  Bluetooth speeds.
- **Real GPS.** Position comes from the simulator's *Simulation > Position*
  menu, not from any receiver. Quality values are whatever you set.
- **`openApplication()` on a real watch.** Over ADB it targets the simulator, so
  it cannot answer whether a real device prompts the user first.
- **The Garmin Connect dependency itself**, which is the thing most likely to
  bite real users.

Use this to prove the protocol. Use a real watch to prove the product.

### Is anything actually listening? Four commands that settle it

"There is no data connection" means the simulator dialled port 7381 and nobody
answered. `adb forward` maps **host 7381 to device 7381**, so the *Android app*
has to be the one listening and the *simulator* is the one connecting. If the
app is not listening, no amount of re-running the forward will help.

Run these in order and stop at the first one that is wrong.

```bash
# 1. Is the device visible, and is there exactly one?
adb devices

# 2. Is the forward actually in place? Should print: tcp:7381 tcp:7381
adb forward --list

# 3. THE IMPORTANT ONE. Is the app listening on 7381 inside the device?
adb shell netstat -tln | grep 7381
#    A line back  -> the SDK is listening, the problem is on the simulator side
#    Nothing back -> the SDK never opened the socket; see below

# 4. What is the SDK actually doing?
adb logcat | grep -iE "connectiq|garmin|7381"
```

**If step 3 prints nothing**, the app is not in TETHERED mode, or `initialize()`
never reached `onSdkReady`. Check the app's own log pane: it should say
`initialising SDK in TETHERED mode` and then `SDK ready`. If it says the first
but never the second, initialisation is failing and step 4 will say why.

**If step 3 prints a line but the simulator still refuses**, the socket exists
and the failure is between the simulator and adb. Restart the simulator, redo
the forward, then `Connection > Start`.

### Reading the connection state

The app polls every two seconds and logs the transitions, because the SDK sends
no event when the simulator attaches over ADB. Three states, three meanings:

| Log line | What it means |
|---|---|
| `device reports UNKNOWN` at startup | Normal. The SDK invents a stub device called `Simulator (12345)` whether or not anything is attached. |
| `connected=0` and no `SIMULATOR ATTACHED` line | The simulator has **not** dialled in. Sends will return `FAILURE_UNKNOWN`. Fix the forward and Connection > Start. |
| `SIMULATOR ATTACHED` | The socket is live. Messages should work. |

Because that stub device always exists, "Find watch" succeeding proves nothing.
Wait for `SIMULATOR ATTACHED` before pressing anything else.

The switch starts in **ADB simulator** mode deliberately. Flipping it tears the
SDK down and back up, which closes the listening socket, so if you flip it after
the simulator has attached you have to redo Connection > Start.

### If the simulator still says ADB Disconnected

- `adb forward --list` should show `tcp:7381 tcp:7381`. If it is empty, the
  forward was cleared, which happens whenever the adb server restarts.
- Only one adb server should be running. Android Studio starts its own; a
  separate Homebrew `adb` on a different version will fight with it. Check with
  `adb version`, and `adb kill-server` then let Studio start it again.
- The app must be in the foreground. The socket lives with the app process, so
  backgrounding or killing it drops the connection.
- Redo step 4 after every emulator restart.

The app id is hard-coded in `Protocol.WATCH_APP_ID` and must match `id` in the
watch project's `manifest.xml`. If you regenerate the UUID on the watch side,
change it here too or the phone will report "not installed" on a watch that
plainly has it.

---

## The simulator bug that makes the watch look broken

Over the tethered (ADB) transport the Connect IQ simulator stamps every message
it sends with an **empty application id** instead of the `id` from
`manifest.xml`. The Android SDK routes inbound messages by that id, so a
listener registered for the real id is never called.

Nothing errors. The phone just goes deaf. The watch transmits, gets no
acknowledgement, retries into a socket nobody is reading, and the simulator
eventually dies with `Socket Error in packet header 0`. The crash looks like a
fault in the watch code; it is not.

`WatchLink.listenForMessages()` therefore registers exactly **one** listener,
for the id that transport actually uses: `IQApp("")` on TETHERED, the real id on
WIRELESS. `sendMessage` uses the same app object, so both directions agree.

Do not register both. The SDK keys its registration per device, so the second
call replaces the first rather than adding to it, and you end up listening on
whichever id you passed last. A message arriving with no handler takes the SDK's
reader thread down with it, which closes the socket and is what the simulator is
complaining about.

The same transport reports two other things wrongly, and both are advisory here
rather than gates:

- **Device status stays `UNKNOWN`.** The simulator is never promoted to
  `CONNECTED`, so `connectedDevices` is empty and only `knownDevices` has it.
  The listener is registered regardless.
- **`getApplicationInfo()` answers `UNKNOWN` or "not installed"** for an app
  that is plainly running, because there is no real device behind the socket to
  ask.

`openApplication()` is genuinely unavailable over ADB and always throws
`InvalidStateException`, whatever the SDK state says. It is skipped in TETHERED
mode: the watch app is already running in the simulator, so there is nothing to
launch.

Reported at
[forums.garmin.com/developer/connect-iq/f/discussion/379720](https://forums.garmin.com/developer/connect-iq/f/discussion/379720/android-mobile-sdk---tethered-connection---app-status-unknown).

---

## Never call the SDK from the main thread

Over the tethered transport `sendMessage` writes to the ADB socket
**synchronously on the calling thread**. Android forbids network I/O on the main
thread, so calling it straight from a click handler dies with
`NetworkOnMainThreadException` and nothing is ever sent. The exception names
neither Garmin nor the socket, so it reads like an unrelated bug.

In WIRELESS mode the same call is a Binder round trip to Garmin Connect rather
than a socket write, so it happens not to trip the check. That is why this only
bites on the simulator.

`WatchLink` puts every call that can touch the wire on a single background
thread and hops results back to the main thread. Keep that arrangement in
TreeMapper proper.

---

## When the simulator dies with "Socket Error in packet header 0"

Read that number. It is a byte count, and 0 means the simulator got EOF trying
to read a packet header: **the phone closed the socket.** The simulator is the
victim here, not the cause, and nothing you change in the watch app will fix it.

Almost always that means the SDK's reader thread threw while dispatching an
inbound message and died, taking the connection with it. The exception never
reaches this app, because it happens inside the SDK, so the only place to see it
is logcat:

```bash
adb logcat -c                       # clear, then press Hello in the app
adb logcat -d | grep -iE "connectiq|garmin|AndroidRuntime|FATAL|Exception"
```

Two things to look for:

- A stack trace naming `com.garmin.android.connectiq` — the SDK died. The trace
  names the method, which is usually enough to work out what it choked on.
- Nothing at all — then the socket was closed for a transport reason: the adb
  forward was cleared, or something else on the Mac holds port 7381. Check with
  `adb forward --list` and, on the Mac, `lsof -nP -i :7381`.

`WatchLink.registerEmptyId` is the first thing to A/B. It is the only place this
app registers two listeners on one device, and a dispatch that cannot find a
home is a plausible way to kill that thread. Set it to false, rebuild, and see
whether the crash moves.

---

## Running it

Open `android-demo/` in Android Studio and let it sync. There is no
`gradle-wrapper.jar` in the repo, so the command line `./gradlew` will not work
until Studio generates one, or you run `gradle wrapper` once.

Then, in order:

| Button | What it proves |
|---|---|
| **Find watch** | The SDK is up, Garmin Connect is reachable, and a device is paired. Reports connected vs known so "paired but asleep" is distinguishable from "no watch". |
| **Open watch app** | `openApplication()` works. Watch the wrist: this is the open question in `DESIGN.md`, whether it launches silently or prompts. |
| **Hello** | Two-way messaging. The watch answers with a `ready` message carrying live fix quality. |
| **Ping** | Same, as a keepalive. Useful for watching quality climb while the receiver converges. |
| **Request GPS point** | The whole thing. Round trip time is shown. |

The log pane records every message in both directions verbatim, and is
selectable so you can paste it into a bug report.

---

## The one check worth doing carefully

The point card prints a `type` line: the **runtime Java class** of the latitude
that arrived.

It must say `Double`.

If it says `Float`, the SDK narrowed the value somewhere and you have lost about
half the decimal places. A latitude needs more than the ~7 significant digits a
32-bit float carries, so the coordinate will still look plausible and will be
wrong by metres. The app logs a warning if this happens. This is the single
easiest thing to get wrong in the integration and the hardest to spot later.

The latitude and longitude are printed to 7 decimal places, roughly 1 cm, so a
narrowed value is visible directly in the trailing digits.

---

## A note on the tethered transport

It throttles to real Bluetooth speeds rather than giving a best-case link, which
makes it the right place to test timing and reconnect behaviour, not just
correctness.

`openStore` is not available over ADB. The button is disabled in that mode.

---

## If it does not compile

**`ConnectIQ.getInstance` signature.** Some SDK versions take the connect type
alone, without a `Context`. If the two-argument call does not resolve, drop the
first argument. There is a comment at that line.

**Dependency not found.** The `@aar` suffix is required; Gradle will not resolve
the artifact without it. Check Maven Central for a version newer than 2.4.0.

---

## What this is not

No server calls, no storage, no permissions beyond Bluetooth, no retry logic. It
is a wire test. The retry, dedupe and offline behaviour described in
`PROTOCOL.md` belong in TreeMapper proper, not here.

One thing it does not exercise: **duplicate handling**. The watch holds a point
until the transport acknowledges it, so if an ack is lost after you have already
stored the point you will see it twice. Deduplicate on `n` in the real app.
