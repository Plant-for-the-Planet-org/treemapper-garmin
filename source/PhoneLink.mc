import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Everything that talks to the TreeMapper phone app.
//!
//! The model is a mailbox, not a socket: parcels are posted in both
//! directions and an event fires on arrival. There is no session, no
//! handshake at the transport level, and no delivery guarantee, so this class
//! adds the three things the field needs:
//!
//!   1. One transmit in flight at a time. The BLE link returns BLE_QUEUE_FULL
//!      if you push several at once, and a dropped point is lost work.
//!   2. An explicit acknowledgement, so the watch only lets go of a fix once
//!      the phone actually has it.
//!   3. A view of whether anyone is listening, which is not the same thing as
//!      whether a phone is paired.
//!
//! PROTOCOL VERSION 2. Keep this in step with the phone app.
//!
//! Version 2 made the link a stream. The watch posts its position on a fixed
//! interval instead of answering one request at a time, so the request and
//! acknowledgement messages of version 1 are gone: `fix` and `err` no longer
//! exist, and `pt` no longer carries `r` or `src`. See PROTOCOL.md.
//!
//! Phone to watch
//!   {"c":"hello"}            identify, ask for current state
//!   {"c":"ping"}             keepalive, answered with a state message
//!   {"c":"rate", "ms":<n>}   change the stream interval
//!
//! Watch to phone
//!   {"t":"ready", "v":2, "sid":<n>, "q":<0-4>, "gps":<0|1>, "mb":<0|1>,
//!                 "st":"live"|"paused", "ms":<n>, "n":<seq>, "drop":<n>}
//!   {"t":"pt",    "sid":<n>, "n":<seq>, "lat":<Double>, "lon":<Double>,
//!                 "alt":<Float, absent if none>, "q":<0-4>, "ts":<epoch s>,
//!                 "spd":<Float, absent if none>}
//!
//! Every point carries `q`, the raw Position.Quality value, and nothing is
//! filtered on the watch. The phone decides what is good enough, and with a
//! point arriving every second it has plenty to choose from.
//! Protocol version. Module scope, not a class constant: Monkey C does not
//! expose a class const as ClassName.CONST without an instance.
const PROTOCOL_VERSION = 2;

class PhoneLink {

    private var _onCommand as Method or Null = null;
    private var _listener as TransmitListener or Null = null;

    private var _busy as Boolean = false;
    private var _appSeenMs as Number = 0;       // last inbound message, ever
    private var _onSent as Method or Null = null;

    function initialize() {
    }

    //! onCommand is invoked with the parsed inbound Dictionary.
    //! onSent is invoked with a Boolean, true when the last transmit landed.
    function start(onCommand as Method, onSent as Method) as Void {
        _onCommand = onCommand;
        _onSent = onSent;
        _listener = new TransmitListener(self.weak());
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function stop() as Void {
        Communications.registerForPhoneAppMessages(null);
        _onCommand = null;
        _onSent = null;
        _listener = null;
        _busy = false;
    }

    // ---- inbound ----------------------------------------------------------

    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        _appSeenMs = System.getTimer();

        // The phone SDK carries a List<Object>, so a Dictionary sent from
        // Android or iOS can arrive either bare or wrapped in an Array,
        // depending on SDK version. Accept both rather than silently ignoring
        // half of them, which looks exactly like a dead Bluetooth link.
        var payload = unwrap(msg.data);
        if (payload == null) {
            return;
        }

        var cb = _onCommand;
        if (cb != null) {
            // Keep this cheap. The watchdog kills a callback that runs long,
            // and this one fires on the radio's schedule, not ours.
            cb.invoke(payload);
        }
    }

    //! Find the payload dictionary in whatever the phone sent.
    private function unwrap(data) as Dictionary or Null {
        if (data instanceof Dictionary) {
            return data;
        }
        if (data instanceof Array) {
            for (var i = 0; i < data.size(); i++) {
                var item = data[i];
                if (item instanceof Dictionary) {
                    return item;
                }
            }
        }
        return null;
    }

    // ---- outbound ---------------------------------------------------------

    //! True when a transmit is already in flight. The caller should wait
    //! rather than stacking sends.
    function isBusy() as Boolean {
        return _busy;
    }

    //! Post one parcel. Returns false when the link is busy or unavailable.
    //!
    //! There is no outbox behind this. A stream point that cannot go now is
    //! dropped and counted, because the next tick already has a better one.
    function send(payload as Dictionary) as Boolean {
        if (_busy) { return false; }

        // The watch never speaks first. Transmitting before the companion app
        // has made contact is a blind send: on the tethered transport it raises
        // a modal "no data connection" error in the simulator, once per
        // attempt, and on any transport it cannot succeed anyway. Hold the
        // payload instead; it goes out the moment the phone says something.
        if (!hasHeardFromPhone()) {
            return false;
        }

        if (!isPhoneConnected()) {
            return false;
        }

        var listener = _listener;
        if (listener == null) { return false; }

        _busy = true;
        Communications.transmit(stripNulls(payload), null, listener);
        return true;
    }

    //! Copy a payload without its null values.
    //!
    //! A null inside a Dictionary has to survive serialisation into a Java Map
    //! on the other side of the link, and that path is a prime suspect for the
    //! simulator crash seen on the tethered connection. An absent key and a
    //! null value mean the same thing to the phone, so drop them.
    private function stripNulls(payload as Dictionary) as Dictionary {
        var clean = {};
        var keys = payload.keys();
        for (var i = 0; i < keys.size(); i++) {
            var k = keys[i];
            var v = payload[k];
            if (v != null) {
                clean[k] = v;
            }
        }
        return clean;
    }

    //! Called back by the transmit listener.
    function onTransmitResult(ok as Boolean) as Void {
        // The Android SDK's ADB transport is reported to fire twice for one
        // send, SUCCESS then FAILURE_UNKNOWN. Without this guard the spurious
        // second callback would mark a delivered point as failed and leave the
        // link showing a backlog that is not there.
        if (!_busy) { return; }

        _busy = false;

        var cb = _onSent;
        if (cb != null) {
            cb.invoke(ok);
        }
    }

    // ---- link state -------------------------------------------------------

    //! Whether a phone is paired and in range. This is the Garmin Connect
    //! link, which is the only signal the watch gets. It does not prove that
    //! TreeMapper itself is open, which is why hasHeardFromPhone() exists.
    function isPhoneConnected() as Boolean {
        var settings = System.getDeviceSettings();
        if (settings has :phoneConnected) {
            return settings.phoneConnected;
        }
        return true;   // very old products: assume yes and let transmit fail
    }

    //! Has the companion app ever sent us anything since the app opened?
    //!
    //! This distinguishes "no phone" from "phone there, TreeMapper closed",
    //! which are different problems with different fixes for the user. It is
    //! deliberately "ever", not "recently": a tree can take minutes, and
    //! warning that the app has gone quiet when it is simply idle would train
    //! people to ignore the badge.
    function hasHeardFromPhone() as Boolean {
        return _appSeenMs != 0;
    }
}

//! Transmit result callback.
//!
//! Holds a WeakReference back to the link. A strong reference would form a
//! cycle, and Monkey C frees by reference counting, so a cycle is a permanent
//! leak rather than something the collector cleans up later.
class TransmitListener extends Communications.ConnectionListener {

    private var _link as WeakReference;

    function initialize(link as WeakReference) {
        ConnectionListener.initialize();
        _link = link;
    }

    function onComplete() as Void {
        if (_link.stillAlive()) {
            var link = _link.get() as PhoneLink;
            link.onTransmitResult(true);
        }
    }

    function onError() as Void {
        if (_link.stillAlive()) {
            var link = _link.get() as PhoneLink;
            link.onTransmitResult(false);
        }
    }
}
