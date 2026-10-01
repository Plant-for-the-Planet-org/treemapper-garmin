package org.plantfortheplanet.treemapper.garmindemo

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.ScrollView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQDevice
import org.plantfortheplanet.treemapper.garmindemo.databinding.ActivityMainBinding
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * A bench harness for the TreeMapper watch link.
 *
 * It is deliberately not the TreeMapper modal. It exposes every step of the
 * handshake separately so that when something fails in the field you can tell
 * which step failed: SDK init, finding the device, finding the app, launching
 * the app, or the messages themselves.
 *
 * The one thing it checks that a pretty UI would hide: the runtime type of the
 * latitude that comes back. See the note by `latitudeType`.
 */
class MainActivity : AppCompatActivity(), WatchLink.Listener {

    private lateinit var ui: ActivityMainBinding
    private lateinit var link: WatchLink

    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.UK)
    private val logLines = StringBuilder()
    private var pendingRequestId: Int? = null
    private var requestSentAt = 0L

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        log(if (granted) "BLUETOOTH_CONNECT granted" else
            "BLUETOOTH_CONNECT denied. Garmin Connect holds the radio, so this " +
            "often still works. Continuing.")
        startLink()
    }

    /** WIRELESS needs Garmin Connect. TETHERED does not. See the README. */
    private fun currentType(): ConnectIQ.IQConnectType =
        if (ui.switchTethered.isChecked) ConnectIQ.IQConnectType.TETHERED
        else ConnectIQ.IQConnectType.WIRELESS

    private fun startLink() {
        link = WatchLink(this, this)
        link.start(currentType())
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Before anything else, so a thread that dies during SDK start-up is
        // still recorded.
        CrashLog.install(this)
        ui = ActivityMainBinding.inflate(layoutInflater)
        setContentView(ui.root)

        ui.switchTethered.setOnCheckedChangeListener { _, checked ->
            log(if (checked)
                "switching to ADB simulator. Order matters: this app must be " +
                "running first, then adb forward, then Connection > Start in " +
                "the simulator."
            else
                "switching to a real watch over Garmin Connect.")
            if (this::link.isInitialized) link.stop()
            startLink()
        }

        ui.buttonRefresh.setOnClickListener { link.refreshDevice() }
        ui.buttonOpenApp.setOnClickListener { link.openWatchApp() }
        ui.buttonHello.setOnClickListener { link.sendHello() }
        ui.buttonPing.setOnClickListener { link.sendPing() }
        ui.buttonFix.setOnClickListener {
            pendingRequestId = link.requestFix()
            requestSentAt = System.currentTimeMillis()
            ui.textPoint.text = getString(R.string.waiting_for_point)
        }
        ui.buttonStore.setOnClickListener { link.openStoreListing() }
        ui.buttonCopy.setOnClickListener { copyLog() }
        ui.buttonClear.setOnClickListener {
            logLines.setLength(0)
            ui.textLog.text = ""
        }

        CrashLog.drain(this)?.let { previous ->
            log("=== A THREAD DIED SINCE THE LAST RUN ===")
            previous.trim().lines().forEach { log("  $it") }
            log("=== end of previous crash ===")
        }

        log("app id ${Protocol.WATCH_APP_ID}")
        log("protocol v${Protocol.VERSION}")
        requestPermissionThenStart()
    }

    override fun onDestroy() {
        if (this::link.isInitialized) link.stop()
        super.onDestroy()
    }

    private fun requestPermissionThenStart() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                permissionLauncher.launch(Manifest.permission.BLUETOOTH_CONNECT)
                return
            }
        }
        startLink()
    }

    // ---- WatchLink.Listener ---------------------------------------------

    override fun onLog(line: String) = log(line)

    override fun onSdkState(ready: Boolean, detail: String) {
        ui.textSdk.text = getString(R.string.sdk_fmt, detail)
        setButtonsEnabled(ready)
    }

    override fun onDeviceChanged(device: IQDevice?, status: String) {
        ui.textDevice.text = if (device == null) {
            getString(R.string.no_device)
        } else {
            getString(R.string.device_fmt, device.friendlyName ?: "unnamed", status)
        }
    }

    override fun onAppState(installed: Boolean, detail: String) {
        ui.textApp.text = getString(R.string.app_fmt, detail)
        ui.buttonStore.isEnabled = !installed
    }

    override fun onMessage(payload: Map<String, Any?>) {
        when (val parsed = Protocol.parse(payload)) {
            is Protocol.Inbound.Ready -> {
                ui.textWatch.text = getString(
                    R.string.watch_fmt,
                    Protocol.qualityLabel(parsed.quality),
                    parsed.quality,
                    if (parsed.gpsRunning) "on" else "off",
                    if (parsed.multiBand) "multi-band" else "single-band",
                    parsed.buffered
                )
                if (parsed.version != Protocol.VERSION) {
                    log("PROTOCOL MISMATCH: watch v${parsed.version}, " +
                        "phone v${Protocol.VERSION}")
                }
            }

            is Protocol.Inbound.Point -> showPoint(parsed)

            is Protocol.Inbound.Error ->
                log("watch error: ${parsed.code} (r=${parsed.requestId})")

            is Protocol.Inbound.Unknown ->
                log("unknown message type: ${parsed.raw}")
        }
    }

    private fun showPoint(p: Protocol.Inbound.Point) {
        val roundTrip = if (p.requestId != null && p.requestId == pendingRequestId) {
            val ms = System.currentTimeMillis() - requestSentAt
            pendingRequestId = null
            "${ms} ms"
        } else {
            "unsolicited"
        }

        // Seven decimal places is about 1 cm. If the latitude arrived as a
        // Float the trailing digits will be visibly wrong, which is the whole
        // reason this line prints them.
        val text = buildString {
            append("lat  ").append(String.format(Locale.UK, "%.7f", p.latitude)).append('\n')
            append("lon  ").append(String.format(Locale.UK, "%.7f", p.longitude)).append('\n')
            append("alt  ").append(p.altitude?.let {
                String.format(Locale.UK, "%.1f m", it)
            } ?: "-").append('\n')
            append("qual ").append(Protocol.qualityLabel(p.quality))
                .append(" (").append(p.quality).append(")\n")
            append("time ").append(stamp.format(Date(p.timestamp * 1000L))).append('\n')
            append("seq  #").append(p.seq).append("  from ").append(p.source).append('\n')
            append("trip ").append(roundTrip).append('\n')
            append("type ").append(p.latitudeType)
        }
        ui.textPoint.text = text

        if (p.latitudeType == "String") {
            log("latitude arrived as text, which is the watch's SAFE_COORDS " +
                "mode. Precision is preserved; nothing to fix.")
        } else if (p.latitudeType != "Double") {
            log("WARNING: latitude arrived as ${p.latitudeType}, not Double. " +
                "Precision is lost. Check the watch is sending toDegrees() values.")
        }
    }

    // ---- helpers ---------------------------------------------------------

    private fun setButtonsEnabled(enabled: Boolean) {
        ui.buttonRefresh.isEnabled = enabled
        ui.buttonOpenApp.isEnabled = enabled
        ui.buttonHello.isEnabled = enabled
        ui.buttonPing.isEnabled = enabled
        ui.buttonFix.isEnabled = enabled
    }

    /**
     * Put the whole log on the clipboard, with a short header naming the
     * transport, the app id and the SDK/device/app lines. A pasted log without
     * that header is half a bug report: the same failure reads completely
     * differently on WIRELESS and TETHERED.
     */
    private fun copyLog() {
        if (logLines.isEmpty()) {
            Toast.makeText(this, R.string.nothing_to_copy, Toast.LENGTH_SHORT).show()
            return
        }

        val header = buildString {
            append("TreeMapper Watch Test\n")
            append("time      ").append(stamp.format(Date())).append('\n')
            append("transport ").append(currentType().name).append('\n')
            append("app id    ").append(Protocol.WATCH_APP_ID).append('\n')
            append("protocol  v").append(Protocol.VERSION).append('\n')
            append("android   ").append(Build.VERSION.RELEASE)
                .append(" (API ").append(Build.VERSION.SDK_INT).append(")\n")
            append("model     ").append(Build.MANUFACTURER).append(' ')
                .append(Build.MODEL).append('\n')
            append('\n')
            append(ui.textSdk.text).append('\n')
            append(ui.textDevice.text).append('\n')
            append(ui.textApp.text).append('\n')
            append(ui.textWatch.text).append('\n')
            append('\n')
            append("--- last point ---\n")
            append(ui.textPoint.text).append('\n')
            append('\n')
            append("--- log ---\n")
        }

        val text = header + logLines.toString()
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("TreeMapper watch log", text))

        // Android 13+ shows its own clipboard confirmation, so do not add a
        // second one on top of it.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val lines = text.count { it == '\n' } + 1
            Toast.makeText(this, getString(R.string.copied_fmt, lines),
                Toast.LENGTH_SHORT).show()
        }
    }

    private fun log(line: String) {
        logLines.append(stamp.format(Date())).append("  ").append(line).append('\n')
        ui.textLog.text = logLines
        ui.scrollLog.post { ui.scrollLog.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
