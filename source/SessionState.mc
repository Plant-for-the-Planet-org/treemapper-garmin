import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;

//! Orchestration. This is the brain: it owns the receiver, the phone link and
//! the stream timer, and it is the only thing the views talk to.
//!
//! Streaming session model. The app opens, the receiver comes up, and from the
//! moment the phone has made contact the watch posts its position on a fixed
//! interval, one second by default. Nobody has to touch the watch: it is set
//! down and left alone, and TreeMapper decides which of those points is worth
//! recording. The person can pause from the wrist, and the phone can change
//! the interval.
//!
//! The watch still holds nothing. There is no outbox and no session record: a
//! point is built from the receiver, handed to the radio and forgotten. At one
//! point per second there is no useful way to retry, because by the time a
//! retry went out the coordinate would be stale. A point that does not make it
//! is dropped and counted, and the count is reported to the phone so the loss
//! is visible rather than silent.
//!
//! What that trades away: there is no per-point delivery guarantee any more.
//! The old flow held one fix until the phone acknowledged it, which a stream
//! cannot do. What replaces it is liveness: the stream view says how long ago
//! the phone last took anything, so a link that has gone quiet is obvious at a
//! glance rather than discovered at the end of the day.

var gSession as SessionState or Null = null;

// Phone link states.
enum {
    LINK_CONNECTED = 0,   // phone in range and the companion app has spoken
    LINK_WAITING   = 1,   // phone in range, companion app has never spoken
    LINK_OFFLINE   = 2    // no phone in range at all
}

//! Stream interval. One second is the default and the fastest rate worth
//! asking for: the link is Bluetooth relayed through Garmin Connect, and a
//! tick that arrives while the previous point is still in flight is dropped,
//! not queued. The phone can widen it with a "rate" command, which is how the
//! interval gets tuned after real battery measurements without a new build.
const DEFAULT_INTERVAL_MS = 1000;
const MIN_INTERVAL_MS = 500;
const MAX_INTERVAL_MS = 60000;

//! How often a "ready" goes out when no points are flowing, so a paused or
//! fixless watch still proves it is alive.
const HEARTBEAT_MS = 5000;

//! Delivery older than this makes the stream view say so. Not an error: the
//! link is allowed to be quiet, but a watch left on a stump should show it.
const STALE_DELIVERY_MS = 6000;

class SessionState {

    // ---- state the views read --------------------------------------------

    public var quality as Number = 0;          // Position.Quality, 0..4
    public var link as Number = LINK_OFFLINE;

    //! The quality at or above which a fix is called good. This is a WARNING
    //! threshold, not a gate. The watch streams whatever the receiver reports,
    //! with the quality attached, and the phone decides what to keep. This
    //! value only colours the interface.
    public var minQuality as Number = 3;

    // ---- collaborators ----------------------------------------------------

    private var _gps as GpsService;
    private var _phone as PhoneLink;

    //! The stream runs off its own timer, not off the view's render timer.
    //! The cadence has to survive a view change and a dark screen, and tying
    //! it to whatever is on screen would make it stop when it matters most.
    private var _streamTimer as Timer.Timer or Null = null;

    // ---- stream state -----------------------------------------------------

    private var _paused as Boolean = false;
    private var _intervalMs as Number = DEFAULT_INTERVAL_MS;

    //! Identifies this run of the app, so the phone can tell a restart from a
    //! continuation. `n` alone cannot: it counts from 1 every time.
    private var _sessionId as Number = 0;

    private var _seq as Number = 0;         // points handed to the radio
    private var _sent as Number = 0;        // points the radio confirmed
    private var _dropped as Number = 0;     // points that never left
    private var _lastDeliveredMs as Number = 0;   // 0 means never
    private var _lastReadyMs as Number = 0;
    private var _inFlight as Boolean = false;

    // Work asked for by the phone, deferred out of the receive callback.
    private var _pendingAnnounce as Boolean = false;
    private var _pendingRateMs as Number or Null = null;

    function initialize() {
        _gps = new GpsService();
        _phone = new PhoneLink();
    }

    // ---- lifecycle --------------------------------------------------------

    //! Called once from AppBase.onStart. The receiver comes up immediately and
    //! stays warm for as long as the app is open, and the stream timer starts
    //! with it. Points only actually leave once the phone has made contact,
    //! because the watch cannot transmit to nobody.
    function startSession() as Void {
        _sessionId = Time.now().value();
        _seq = 0;
        _sent = 0;
        _dropped = 0;
        _lastDeliveredMs = 0;
        _lastReadyMs = 0;
        _inFlight = false;
        _paused = false;
        _intervalMs = DEFAULT_INTERVAL_MS;

        _gps.start();
        _phone.start(method(:onPhoneCommand), method(:onTransmitResult));

        // Not announceReady() directly: this runs inside AppBase.onStart,
        // before any view exists and before the link has settled. The first
        // stream tick will send it.
        _pendingAnnounce = true;

        startStreamTimer();
    }

    //! Called from AppBase.onStop. Releasing the receiver here is not
    //! optional: Connect IQ never switches it off on its own. The stream timer
    //! goes with it, or it keeps firing against a dead link.
    function endSession() as Void {
        stopStreamTimer();
        _gps.stop();
        _phone.stop();
    }

    function gps() as GpsService {
        return _gps;
    }

    // ---- the stream -------------------------------------------------------

    private function startStreamTimer() as Void {
        stopStreamTimer();
        var t = new Timer.Timer();
        t.start(method(:onStreamTick), _intervalMs, true);
        _streamTimer = t;
    }

    //! Clearing the field is not tidiness, it is the leak fix. A Timer holds
    //! the Method, the Method holds a strong reference back to this object,
    //! and Monkey C frees by reference counting, so that cycle is permanent
    //! unless one side lets go. endSession() is the path that matters.
    private function stopStreamTimer() as Void {
        var t = _streamTimer;
        if (t != null) {
            t.stop();
            _streamTimer = null;
        }
    }

    //! One beat of the stream. Reads the receiver, serves whatever the phone
    //! asked for, posts a point, and falls back to a heartbeat when there is
    //! no point to post.
    //!
    //! At most one parcel leaves per tick, and the order matters: a tick that
    //! spends its slot answering the phone does not then try to post a point
    //! and count the failure as a dropped one.
    function onStreamTick() as Void {
        quality = _gps.quality();
        refreshLink();

        if (servePhoneRequests()) {
            return;
        }

        var posted = false;
        if (!_paused) {
            posted = streamPoint();
        }
        if (!posted) {
            maybeHeartbeat();
        }
    }

    //! Is the radio free and is there anybody out there. Everything that
    //! transmits goes through this first, so a session with no phone in range
    //! costs nothing: no payload is built, and nothing is counted as lost.
    private function canSend() as Boolean {
        return link == LINK_CONNECTED and !_inFlight and !_phone.isBusy();
    }

    //! Post the current position.
    //!
    //! Nothing is kept on failure. A point is only worth what its timestamp
    //! says, and holding a second old coordinate to retry next tick would put
    //! a worse point on the wire than the one that tick already has.
    //!
    //! `_dropped` counts only points lost while the link was up: the radio
    //! was still busy with the last one, or the transmit was refused. Points
    //! not even attempted because no phone is in range are not counted. They
    //! would run to thousands over one lunch break and bury the number that
    //! is actually useful, which is whether this interval is too fast for
    //! this link. The status line already says when the phone is missing.
    private function streamPoint() as Boolean {
        if (link != LINK_CONNECTED) {
            return false;
        }

        // Checked before building anything: snapshot() allocates, and at one
        // allocation a second a pointless one is not free.
        if (!_gps.hasPosition()) {
            return false;
        }

        if (_inFlight or _phone.isBusy()) {
            _dropped++;
            return false;
        }

        var snapshot = _gps.snapshot();
        if (snapshot == null) {
            return false;
        }

        // Built key by key so nothing null is ever present. A Dictionary
        // carrying a null has to survive serialisation into a Java Map on the
        // other side of the link, and that path is a known crash suspect.
        var point = {
            "t"   => "pt",
            "sid" => _sessionId,
            "n"   => _seq + 1,
            "lat" => snapshot["lat"],
            "lon" => snapshot["lon"],
            "q"   => snapshot["q"],
            "ts"  => snapshot["ts"]
        };
        if (snapshot["alt"] != null) { point["alt"] = snapshot["alt"]; }
        if (snapshot["spd"] != null) { point["spd"] = snapshot["spd"]; }

        if (!_phone.send(point)) {
            // No phone in range, or the companion app has never spoken to us
            // so the watch has nobody to speak to.
            _dropped++;
            return false;
        }

        // Only now does this point own a sequence number. A gap in `n` on the
        // phone therefore means a point was lost in transit, not that the
        // watch declined to build one.
        _seq++;
        _inFlight = true;
        return true;
    }

    //! Prove the watch is alive when no points are flowing: paused, no fix
    //! yet, or nothing to say. Rate limited so it never competes with the
    //! stream for the radio.
    private function maybeHeartbeat() as Void {
        if (!canSend()) { return; }

        var now = System.getTimer();
        if ((now - _lastReadyMs) < HEARTBEAT_MS) { return; }

        if (announceReady()) {
            _lastReadyMs = now;
        }
    }

    //! Transmit finished.
    function onTransmitResult(ok as Boolean) as Void {
        _inFlight = false;
        if (ok) {
            _sent++;
            _lastDeliveredMs = System.getTimer();
        } else {
            _dropped++;
        }
        refreshLink();
    }

    // ---- pause ------------------------------------------------------------

    //! Stop and start the stream from the wrist.
    //!
    //! Pausing deliberately leaves the receiver running. Switching GNSS off
    //! would save the larger share of the battery, but it would also cost a
    //! cold reacquisition of tens of seconds on resume, and the whole point of
    //! this app is that the fix is already there when it is wanted.
    function togglePause() as Void {
        _paused = !_paused;
        _pendingAnnounce = true;   // tell the phone at once, do not wait 5 s
    }

    function isPaused() as Boolean {
        return _paused;
    }

    // ---- phone commands ---------------------------------------------------

    //! Dispatch for inbound parcels. See PhoneLink for the protocol.
    function onPhoneCommand(data as Dictionary) as Void {
        var c = data["c"];
        if (!(c instanceof String)) { return; }

        if (c.equals("hello") or c.equals("ping")) {
            _pendingAnnounce = true;

        } else if (c.equals("rate")) {
            var ms = data["ms"];
            if (ms instanceof Number) {
                _pendingRateMs = ms;
            }
        }
    }

    //! Do the work the phone asked for, on our own schedule.
    //!
    //! Deliberately never called from onPhoneCommand. Transmitting from inside
    //! the receive callback re-enters the comms stack, and that is the most
    //! likely cause of the simulator crash on the tethered link.
    //! Returns true when it used this tick's transmit slot.
    private function servePhoneRequests() as Boolean {
        var ms = _pendingRateMs;
        if (ms != null) {
            _pendingRateMs = null;
            applyInterval(ms);
            _pendingAnnounce = true;   // confirm the rate actually adopted
        }

        if (_pendingAnnounce and canSend()) {
            // Only clear the flag once the send was actually accepted, so the
            // opening state still reaches a phone that connects later.
            if (announceReady()) {
                _pendingAnnounce = false;
                _lastReadyMs = System.getTimer();
                return true;
            }
        }
        return false;
    }

    //! Adopt a new stream interval, clamped to what the link can actually
    //! carry. Below half a second every other tick would be dropped on a busy
    //! radio, which is worse than asking for less.
    private function applyInterval(ms as Number) as Void {
        var next = ms;
        if (next < MIN_INTERVAL_MS) { next = MIN_INTERVAL_MS; }
        if (next > MAX_INTERVAL_MS) { next = MAX_INTERVAL_MS; }
        if (next == _intervalMs) { return; }

        _intervalMs = next;

        // Restarting the timer from inside its own callback is fine: this tick
        // has already fired, and the new timer takes over from the next one.
        startStreamTimer();
    }

    //! Tell the phone what state the watch is in. Sent on start, in answer to
    //! hello, ping or rate, and as a heartbeat whenever no points are flowing.
    private function announceReady() as Boolean {
        return _phone.send({
            "t"    => "ready",
            "v"    => $.PROTOCOL_VERSION,
            "sid"  => _sessionId,
            "q"    => quality,
            "gps"  => _gps.isRunning() ? 1 : 0,
            "mb"   => _gps.isMultiBand() ? 1 : 0,
            "st"   => _paused ? "paused" : "live",
            "ms"   => _intervalMs,
            "n"    => _seq,
            "drop" => _dropped
        });
    }

    // ---- what the views read ---------------------------------------------

    //! Called from every view's render timer. Cheap by design, and it must
    //! never transmit: the stream timer owns the radio. This only refreshes
    //! what the screen is about to draw.
    function tick() as Void {
        quality = _gps.quality();
        refreshLink();
    }

    private function refreshLink() as Void {
        if (!_phone.isPhoneConnected()) {
            link = LINK_OFFLINE;
        } else if (!_phone.hasHeardFromPhone()) {
            link = LINK_WAITING;
        } else {
            link = LINK_CONNECTED;
        }
    }

    function isLinked() as Boolean {
        return link == LINK_CONNECTED;
    }

    function pointsSent() as Number {
        return _sent;
    }

    function pointsDropped() as Number {
        return _dropped;
    }

    function intervalMs() as Number {
        return _intervalMs;
    }

    //! Seconds since the phone last took a point, or -1 if it never has.
    function secondsSinceDelivery() as Number {
        if (_lastDeliveredMs == 0) { return -1; }
        return (System.getTimer() - _lastDeliveredMs) / 1000;
    }

    //! True when points are flowing and the phone is keeping up.
    function isDeliveryHealthy() as Boolean {
        if (_lastDeliveredMs == 0) { return false; }
        return (System.getTimer() - _lastDeliveredMs) < STALE_DELIVERY_MS;
    }

    //! The one line that says whether this session is working.
    //!
    //! Unlike the old capture screen, this is shown all the time rather than
    //! only on failure. That rule was written for a screen somebody was
    //! looking at while they pressed a button. A watch left on a stump for an
    //! hour is the opposite case: silence is exactly what must not be
    //! mistaken for success.
    function streamStatus() as String {
        if (link == LINK_OFFLINE)  { return "No phone in range"; }
        if (link == LINK_WAITING)  { return "Open TreeMapper on phone"; }
        if (_paused)               { return "Paused"; }
        if (_lastDeliveredMs == 0) { return "Waiting for first point"; }
        if (!isDeliveryHealthy())  {
            return "No delivery " + secondsSinceDelivery().format("%d") + "s";
        }
        return "Sending to TreeMapper";
    }

    function streamColour() as Number {
        if (link == LINK_OFFLINE) { return Theme.OFFLINE; }
        if (link == LINK_WAITING) { return Theme.BUFFERING; }
        if (_paused)              { return Theme.TEXT_DIM; }
        if (!isDeliveryHealthy()) { return Theme.BUFFERING; }
        return Theme.LINKED;
    }

    //! Kept for the acquiring screen, which only needs the link itself.
    function linkWarning() as String {
        if (link == LINK_OFFLINE) { return "No phone in range"; }
        if (link == LINK_WAITING) { return "Open TreeMapper on phone"; }
        return "";
    }

    function linkColour() as Number {
        if (link == LINK_OFFLINE) { return Theme.OFFLINE; }
        if (link == LINK_WAITING) { return Theme.BUFFERING; }
        return Theme.LINKED;
    }

    function minQualityLabel() as String {
        return minQuality >= 4 ? "Good only" : "Usable";
    }

    //! The interval as a short label, e.g. "1.0 s".
    function intervalLabel() as String {
        return (_intervalMs.toFloat() / 1000.0).format("%.1f") + " s";
    }
}
