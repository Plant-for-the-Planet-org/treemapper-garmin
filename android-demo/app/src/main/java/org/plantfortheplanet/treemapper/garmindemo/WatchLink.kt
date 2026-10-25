package org.plantfortheplanet.treemapper.garmindemo

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.android.connectiq.exception.InvalidStateException
import com.garmin.android.connectiq.exception.ServiceUnavailableException

/**
 * Everything that talks to the watch, kept away from the Activity.
 *
 * Three things about this SDK are worth knowing before reading further:
 *
 *  1. **Nothing may be called before `onSdkReady()`.** Calling early throws
 *     `InvalidStateException`, and it is easy to do by accident from onCreate.
 *  2. **In WIRELESS mode every call routes through Garmin Connect Mobile.**
 *     If that app is missing, signed out, or the watch is not paired to it,
 *     calls fail with `ServiceUnavailableException`. That is a user problem
 *     with a user fix, so it is surfaced rather than swallowed. TETHERED mode
 *     bypasses Garmin Connect entirely and speaks to the Connect IQ simulator
 *     over an ADB-forwarded socket, which is why it exists for development.
 *  3. **Callbacks arrive on a background thread.** Everything here hops to the
 *     main thread before calling back, so the UI layer never has to think
 *     about it.
 */
class WatchLink(
    private val context: Context,
    private val events: Listener
) {

    interface Listener {
        fun onLog(line: String)
        fun onSdkState(ready: Boolean, detail: String)
        fun onDeviceChanged(device: IQDevice?, status: String)
        fun onAppState(installed: Boolean, detail: String)
        fun onMessage(payload: Map<String, Any?>)
    }

    private val main = Handler(Looper.getMainLooper())

    /**
     * Every ConnectIQ call that can touch the wire runs here, never on the
     * main thread.
     *
     * Over the tethered transport the SDK writes to the ADB socket
     * **synchronously on the calling thread**. Android forbids network I/O on
     * the main thread, so `sendMessage` from a click handler dies instantly
     * with NetworkOnMainThreadException and the message is never sent.
     *
     * In WIRELESS mode the same call is a Binder round trip to Garmin Connect
     * rather than a socket write, so it happens not to trip the check. Routing
     * both through here costs nothing and removes the difference.
     */
    private val io: ExecutorService = Executors.newSingleThreadExecutor()

    private var connectIQ: ConnectIQ? = null
    private var sdkReady = false
    private var connectType = ConnectIQ.IQConnectType.WIRELESS

    var device: IQDevice? = null
        private set

    private val watchApp = IQApp(Protocol.WATCH_APP_ID)

    /** The id the Connect IQ simulator actually uses over ADB: empty. */
    private val simulatorApp = IQApp("")

    /**
     * Whether to also register a listener for the empty app id.
     *
     * It is the documented workaround for the simulator's empty-applicationId
     * bug, but it is also the only thing in this app that registers two
     * listeners on one device, which makes it the first thing to rule out when
     * the SDK's reader thread dies on an inbound message and closes the socket
     * ("Socket Error in packet header 0" on the simulator).
     *
     * Flip to false and rebuild to A/B it.
     */
    /** The app object this transport routes by. See listenForMessages(). */
    private fun outboundApp(): IQApp =
        if (connectType == ConnectIQ.IQConnectType.TETHERED) simulatorApp else watchApp
    private var listeningForApp = false

    // ---- lifecycle -------------------------------------------------------

    /**
     * @param type WIRELESS talks to a real watch through Garmin Connect Mobile.
     *   TETHERED talks to the Connect IQ simulator over ADB and does NOT need
     *   Garmin Connect at all. See the README for the exact startup order,
     *   which matters: the app must be listening before the simulator dials in.
     */
    fun start(type: ConnectIQ.IQConnectType = ConnectIQ.IQConnectType.WIRELESS) {
        connectType = type

        // If this line does not compile, your SDK version takes the connect
        // type alone: ConnectIQ.getInstance(type).
        val iq = ConnectIQ.getInstance(context, type)
        connectIQ = iq

        log("initialising SDK in ${type.name} mode")
        if (type == ConnectIQ.IQConnectType.TETHERED) {
            log("waiting for the Connect IQ simulator to connect on port 7381")
        }
        // autoUI prompts the user to install or update Garmin Connect when it
        // is missing. That is right for WIRELESS and wrong for TETHERED, where
        // Garmin Connect is not involved at all and the prompt can only get in
        // the way.
        val autoUi = (type == ConnectIQ.IQConnectType.WIRELESS)

        iq.initialize(context, autoUi, object : ConnectIQ.ConnectIQListener {
            override fun onSdkReady() {
                main.post {
                    sdkReady = true
                    log("SDK ready")
                    events.onSdkState(true, "ready")
                    refreshDevice()
                    main.removeCallbacks(watchdog)
                    main.post(watchdog)
                }
            }

            override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus?) {
                main.post {
                    sdkReady = false
                    val detail = status?.name ?: "unknown"
                    log("SDK init failed: $detail")
                    events.onSdkState(false, detail)
                }
            }

            override fun onSdkShutDown() {
                main.post {
                    sdkReady = false
                    log("SDK shut down")
                    events.onSdkState(false, "shut down")
                }
            }
        })
    }

    /**
     * Poll the device's connection state.
     *
     * The tethered transport gives no event when the Connect IQ simulator
     * attaches to the socket: `registerForDeviceEvents` fires once with
     * NOT_CONNECTED and then stays quiet. Without this you cannot tell
     * "simulator has not dialled in yet" from "simulator attached but deaf",
     * and those need completely different fixes.
     */
    private var lastConnected = false

    private val watchdog = object : Runnable {
        override fun run() {
            val iq = connectIQ
            if (iq != null && sdkReady) {
                try {
                    val nowConnected = (iq.connectedDevices ?: emptyList()).isNotEmpty()
                    if (nowConnected != lastConnected) {
                        lastConnected = nowConnected
                        if (nowConnected) {
                            log("SIMULATOR ATTACHED. Messages should work now.")
                            refreshDevice()
                            // The watch deliberately never speaks first, so
                            // until something arrives it shows "waiting for
                            // phone app" even though the socket is up. Greet it,
                            // which is what TreeMapper's modal will do anyway.
                            // Delayed so the listener registration above lands
                            // first.
                            main.postDelayed({
                                log("auto-greeting the watch")
                                sendHello()
                            }, 750)
                        } else {
                            log("simulator detached")
                        }
                        events.onDeviceChanged(
                            device, if (nowConnected) "CONNECTED" else "waiting")
                    }
                } catch (ignored: Exception) {
                }
            }
            main.postDelayed(this, 2000)
        }
    }

    fun stop() {
        main.removeCallbacks(watchdog)
        lastConnected = false
        val iq = connectIQ ?: return
        try {
            val d = device
            if (d != null && listeningForApp) {
                iq.unregisterForApplicationEvents(d, outboundApp())
            }
            if (d != null) {
                iq.unregisterForDeviceEvents(d)
            }
            iq.shutdown(context)
        } catch (e: Exception) {
            log("shutdown: ${e.javaClass.simpleName}")
        }
        listeningForApp = false
        connectIQ = null
    }

    // ---- devices ---------------------------------------------------------

    fun refreshDevice() {
        val iq = connectIQ
        if (iq == null || !sdkReady) {
            log("not ready yet")
            return
        }

        try {
            val connected = iq.connectedDevices ?: emptyList()
            val known = iq.knownDevices ?: emptyList()

            log("connected=${connected.size} known=${known.size}")

            // Prefer a connected device. Fall back to a known one so the UI can
            // say "paired but not connected", which is a different problem.
            val chosen = connected.firstOrNull() ?: known.firstOrNull()
            if (chosen == null) {
                device = null
                events.onDeviceChanged(null, "no device")
                log("no Garmin device found. Is one paired in Garmin Connect?")
                return
            }

            device = chosen
            log("device: ${chosen.friendlyName} (${chosen.deviceIdentifier})")

            iq.registerForDeviceEvents(chosen) { dev, status ->
                main.post {
                    log("device status: ${status?.name}")
                    events.onDeviceChanged(dev, status?.name ?: "?")
                    if (status == IQDevice.IQDeviceStatus.CONNECTED) {
                        listenForMessages()
                        checkApp()
                    }
                }
            }

            // Report what the socket says, not what the device object says.
            // IQDevice.status is stuck on UNKNOWN over ADB, so showing it makes
            // a live link look dead.
            events.onDeviceChanged(
                chosen,
                if (lastConnected) "CONNECTED" else (chosen.status?.name ?: "?"))

            // Listen FIRST, and never gate it on device status or app info.
            //
            // Over the tethered transport the SDK reports the simulator as
            // UNKNOWN and never promotes it to CONNECTED, and
            // getApplicationInfo answers UNKNOWN too, because there is no real
            // device behind the socket to ask. Gating on either one leaves
            // nothing on the phone listening: the watch's transmits are never
            // acknowledged and it retries into a socket nobody reads.
            //
            // Registering a listener for a device that turns out to be absent
            // costs nothing, so register and let the messages decide.
            val status = chosen.status
            if (status != IQDevice.IQDeviceStatus.CONNECTED) {
                log("device reports ${status?.name}. Expected over ADB; " +
                    "registering listeners anyway.")
            }
            listenForMessages()
            checkApp()
        } catch (e: Exception) {
            reportFailure("refreshDevice", e)
        }
    }

    // ---- the watch app ---------------------------------------------------

    fun checkApp() {
        val iq = connectIQ ?: return
        val d = device ?: return

        io.execute {
            try {
                iq.getApplicationInfo(
                    Protocol.WATCH_APP_ID, d,
                    object : ConnectIQ.IQApplicationInfoListener {
                        override fun onApplicationInfoReceived(app: IQApp?) {
                            main.post {
                                val version = app?.version() ?: -1
                                log("watch app installed, version $version")
                                events.onAppState(true, "installed v$version")
                                listenForMessages()
                            }
                        }

                        override fun onApplicationNotInstalled(id: String?) {
                            main.post {
                                // Advisory only. Over ADB this fires even when
                                // the app is running fine in the simulator, so
                                // keep listening regardless.
                                log("app info says NOT installed. Expected " +
                                    "over ADB; still listening for messages.")
                                events.onAppState(false, "unknown (ADB)")
                                listenForMessages()
                            }
                        }
                    })
            } catch (e: Exception) {
                main.post { reportFailure("getApplicationInfo", e) }
            }
        }
    }

    /**
     * Register for messages coming back from the watch.
     *
     * Exactly ONE listener, and which id it uses depends on the transport.
     *
     * Over the tethered (ADB) transport the Connect IQ simulator stamps its
     * outbound messages with an EMPTY application id rather than the id in
     * manifest.xml. The SDK routes inbound messages by that id, so a listener
     * registered for the real id never matches.
     *
     * Registering BOTH does not fix it and appears to make it worse: the SDK
     * keys its registration per device, so the second call replaces the first
     * rather than adding to it. Register the real id second and you are back to
     * having no handler for what actually arrives. An arriving message with no
     * handler takes the SDK's reader thread down with it, the socket closes,
     * and the simulator reports "Socket Error in packet header 0" and dies.
     *
     * So: empty id on TETHERED, real id on WIRELESS. One each, never both.
     *
     * forums.garmin.com/developer/connect-iq/f/discussion/379720
     */
    private fun listenForMessages() {
        val iq = connectIQ ?: return
        val d = device ?: return
        if (listeningForApp) return

        val tethered = connectType == ConnectIQ.IQConnectType.TETHERED
        val target = if (tethered) simulatorApp else watchApp
        val label = if (tethered) "empty id (simulator)" else Protocol.WATCH_APP_ID

        try {
            iq.registerForAppEvents(d, target) { _, _, messageData, status ->
                main.post {
                    val payload = Protocol.unwrap(messageData)
                    if (payload == null) {
                        log("<- unparsable message (status=${status?.name}): $messageData")
                    } else {
                        log("<- $payload")
                        events.onMessage(payload)
                    }
                }
            }
            listeningForApp = true
            log("listening for watch messages on $label")
        } catch (e: Exception) {
            reportFailure("registerForAppEvents", e)
        }
    }

    /** Launch the watch app remotely. This is what makes the modal flow work. */
    fun openWatchApp() {
        val iq = connectIQ ?: return
        val d = device ?: return

        if (connectType == ConnectIQ.IQConnectType.TETHERED) {
            // openApplication asks Garmin Connect to launch an app on a real
            // device. Over ADB there is no device to launch on, and the SDK
            // answers InvalidStateException regardless of readiness. The app is
            // already running in the simulator, so there is nothing to do.
            log("openApplication does nothing over ADB. The watch app is " +
                "already running in the simulator.")
            return
        }

        try {
            log("-> openApplication")
            iq.openApplication(d, watchApp) { _, _, status ->
                main.post {
                    log("openApplication: ${status?.name}")
                }
            }
        } catch (e: Exception) {
            reportFailure("openApplication", e)
        }
    }

    fun openStoreListing() {
        if (connectType == ConnectIQ.IQConnectType.TETHERED) {
            log("openStore is not available over ADB, only on a real device")
            return
        }
        try {
            connectIQ?.openStore(Protocol.WATCH_APP_ID)
        } catch (e: Exception) {
            reportFailure("openStore", e)
        }
    }

    // ---- messages --------------------------------------------------------

    fun sendHello() = send(Protocol.hello(), "hello")

    fun sendPing() = send(Protocol.ping(), "ping")

    /** Ask for one point. Returns the request id so the UI can match the reply. */
    fun setRate(intervalMs: Int) =
        send(Protocol.setRate(intervalMs), "rate ms=$intervalMs")

    private fun send(message: List<Any>, label: String) {
        val iq = connectIQ
        val d = device
        if (iq == null || d == null) {
            log("cannot send $label: no device")
            return
        }
        if (!listeningForApp) {
            log("REFUSING to send $label: no app event listener registered, so " +
                "the watch would have nothing to talk to. Press Find watch.")
            return
        }
        if (!lastConnected && connectType == ConnectIQ.IQConnectType.TETHERED) {
            log("REFUSING to send $label: the Connect IQ simulator has not " +
                "dialled in. Run  adb forward tcp:7381 tcp:7381  then " +
                "Connection > Start in the simulator. Sending now only " +
                "returns FAILURE_UNKNOWN.")
            return
        }

        log("-> $label  ${message.firstOrNull()}")
        io.execute {
            try {
                iq.sendMessage(d, outboundApp(), message) { _, _, status ->
                    main.post { log("   send $label: ${status?.name}") }
                }
            } catch (e: Exception) {
                main.post { reportFailure("sendMessage($label)", e) }
            }
        }
    }

    // ---- errors ----------------------------------------------------------

    private fun reportFailure(what: String, e: Exception) {
        val hint = when (e) {
            is InvalidStateException ->
                if (connectType == ConnectIQ.IQConnectType.TETHERED)
                    "Not supported over ADB. The simulator is not a real device."
                else
                    "SDK not ready. Wait for onSdkReady before calling anything."
            is ServiceUnavailableException ->
                "Garmin Connect Mobile is missing, signed out, or not running."
            else -> e.message ?: ""
        }
        log("$what failed: ${e.javaClass.simpleName}. $hint")
    }

    private fun log(line: String) = events.onLog(line)
}
