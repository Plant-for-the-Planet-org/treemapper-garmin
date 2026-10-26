import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;

//! Send latitude and longitude as text rather than as Double.
//!
//! Doubles are the last numeric type in the payload that has to survive
//! serialisation across the phone link and into Application.Storage, and they
//! are the prime suspect once nulls are ruled out. Text is lossless at seven
//! decimal places, roughly 1 cm.
//!
//! Set this to false to test whether Doubles work on your setup. The phone side
//! accepts either form.
const SAFE_COORDS = true;

//! Everything that touches the GNSS receiver.
//!
//! Session model: the receiver is switched on when the app starts and stays on
//! until the app stops. That is the whole point of the design. A cold multi
//! band fix takes tens of seconds under canopy, so the receiver is kept warm
//! for the length of the plot and every request, from the phone or from the
//! watch button, is answered from an already converged fix in milliseconds.
//!
//! The cost is battery. Roughly a working day on a fenix class device. The
//! alternative, waking the receiver per tree, costs 10 to 60 seconds per tree,
//! which is not a workable field tool.
class GpsService {

    private var _enabled as Boolean = false;
    private var _info as Position.Info or Null = null;
    private var _configuration as Position.Configuration or Null = null;
    private var _startedMs as Number = 0;

    function initialize() {
    }

    //! The best GNSS configuration this device actually supports, or null when
    //! the device has no configuration API at all.
    //!
    //! Multi band (L1 + L5) is the accuracy win under canopy and the reason
    //! this project exists, so it is asked for first. Every option is gated by
    //! hasConfigurationSupport, because one binary runs on several products and
    //! asking for an unsupported configuration is a runtime error.
    //!
    //! Null is a real answer, not a failure. GPSMAP 66 and 86 cap at Connect
    //! IQ 3.0.8 and carry none of the CONFIGURATION_ constants, not even
    //! CONFIGURATION_GPS. Naming one there is a Symbol Not Found at runtime
    //! that the compiler does not catch, so nothing below is referenced until
    //! `has` says it exists, and start() leaves the key out of the options
    //! rather than passing a fallback. Those devices run their own default
    //! constellation, which is the best they can do.
    //!
    //! SAT_IQ is deliberately not in the list. It trades accuracy for battery
    //! by picking the solution dynamically, which is the opposite of what a
    //! survey tool wants.
    private function bestConfiguration() as Position.Configuration or Null {
        if (!(Position has :hasConfigurationSupport) ||
            !(Position has :CONFIGURATION_GPS)) {
            return null;
        }

        // Every enum literal is cast: a literal types as Enum<Configuration>
        // rather than Configuration, which the checker rejects. Each is added
        // only if this device declares it, so the list is per product.
        var fallback = Position.CONFIGURATION_GPS as Position.Configuration;
        var preferred = [] as Array<Position.Configuration>;

        if (Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5) {
            preferred.add(
                Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5 as Position.Configuration);
        }
        if (Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1) {
            preferred.add(
                Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1 as Position.Configuration);
        }
        if (Position has :CONFIGURATION_GPS_GALILEO) {
            preferred.add(Position.CONFIGURATION_GPS_GALILEO as Position.Configuration);
        }
        preferred.add(fallback);

        for (var i = 0; i < preferred.size(); i++) {
            if (Position.hasConfigurationSupport(preferred[i])) {
                return preferred[i];
            }
        }
        return fallback;
    }

    //! True when this device gave us a multi band solution.
    function isMultiBand() as Boolean {
        if (!(Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5)) {
            return false;
        }
        return _configuration == Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5;
    }

    //! Whether this device accepts the Dictionary form of
    //! enableLocationEvents.
    //!
    //! Garmin added the options Dictionary in Connect IQ 3.2.0. Before that
    //! the call takes a bare LOCATION_* value and nothing else. GPSMAP 86 is
    //! 3.0.8 across every part number and GPSMAP 66 ships units at 3.0.8 too,
    //! so handing those the Dictionary everything else uses means the receiver
    //! is asked to start in a form the firmware cannot read.
    //!
    //! There is nothing to feature detect with `has`: the symbol exists on
    //! both generations and only the accepted argument changed, so the
    //! Connect IQ version is the only signal. Nothing is given up on the old
    //! devices, because bestConfiguration() already returns null there and the
    //! Dictionary would have carried :acquisitionType alone.
    private function hasOptionsDictionary() as Boolean {
        var settings = System.getDeviceSettings();
        if (!(settings has :monkeyVersion)) {
            return false;
        }

        var version = settings.monkeyVersion;
        if (version == null or version.size() < 2) {
            return false;
        }

        var major = version[0];
        var minor = version[1];
        if (major == null or minor == null) {
            return false;
        }
        if (major != 3) {
            return major > 3;
        }
        return minor >= 2;
    }

    function start() as Void {
        if (_enabled) { return; }

        _configuration = bestConfiguration();
        _startedMs = System.getTimer();

        // The casts are required: an enum literal types as Enum<T> rather than
        // T, and the options dictionary is declared with the exact types.
        var continuous = Position.LOCATION_CONTINUOUS as Position.LocationAcquisitionType;

        if (!hasOptionsDictionary()) {
            // Connect IQ 3.0.8 and 3.1.x: the bare form is the only one this
            // firmware understands. See hasOptionsDictionary.
            Position.enableLocationEvents(continuous, method(:onPosition));
            _enabled = true;
            return;
        }

        // :configuration is added only when the device has the configuration
        // API. On GPSMAP 66 and 86 there is no constant to pass, so the key is
        // left out and the device picks its own constellation.
        var options = {
            :acquisitionType => continuous
        };
        var configuration = _configuration;
        if (configuration != null) {
            options[:configuration] = configuration;
        }

        Position.enableLocationEvents(options, method(:onPosition));

        _enabled = true;
    }

    //! The receiver does not switch itself off. Every exit path must come
    //! through here or the watch quietly burns its battery.
    function stop() as Void {
        if (!_enabled) { return; }

        // Same version split as start(). Getting this wrong is worse here:
        // a stop the firmware cannot read leaves the receiver running and
        // turns a working day of battery into an afternoon.
        var disable = Position.LOCATION_DISABLE as Position.LocationAcquisitionType;
        if (hasOptionsDictionary()) {
            Position.enableLocationEvents(
                { :acquisitionType => disable }, method(:onPosition));
        } else {
            Position.enableLocationEvents(disable, method(:onPosition));
        }

        _enabled = false;
        _info = null;
    }

    function isRunning() as Boolean {
        return _enabled;
    }

    //! Seconds the receiver has been searching. Shown while acquiring so the
    //! user can tell the difference between slow and broken.
    function warmupSeconds() as Number {
        if (!_enabled) { return 0; }
        return (System.getTimer() - _startedMs) / 1000;
    }

    function onPosition(info as Position.Info) as Void {
        _info = info;
    }

    //! Current fix quality, 0 to 4, matching Position.Quality.
    function quality() as Number {
        var info = _info;
        if (info == null) { return 0; }
        // Position.Info.accuracy is non-null by contract, so no guard here.
        return info.accuracy;
    }

    function hasPosition() as Boolean {
        var info = _info;
        return info != null and info.position != null;
    }

    //! A point ready to put on the wire, or null when the receiver has never
    //! produced a position.
    //!
    //! Note what is NOT here: no quality filtering. The watch reports what the
    //! receiver said and lets the phone decide, so `q` travels with every
    //! point and nothing is silently dropped.
    //!
    //! `ts` is the GPS timestamp of the fix, not the watch clock. Positions are
    //! dead reckoned between real fixes and then freeze, so the phone needs to
    //! know how old a coordinate is to judge it.
    function snapshot() as Dictionary or Null {
        var info = _info;
        if (info == null) { return null; }

        var pos = info.position;
        if (pos == null) { return null; }

        var degrees = pos.toDegrees();   // [Double, Double], full precision

        // Keys are only added when they have a value. Nothing null ever enters
        // this dictionary, because it is written to Application.Storage before
        // it is transmitted and both paths have to serialise it.
        var out = {};

        if ($.SAFE_COORDS) {
            // Seven decimal places is about 1 cm, which is far finer than any
            // GNSS fix. Sending the coordinate as text keeps that precision
            // while keeping Doubles off the wire and out of storage.
            out["lat"] = degrees[0].format("%.7f");
            out["lon"] = degrees[1].format("%.7f");
        } else {
            out["lat"] = degrees[0];
            out["lon"] = degrees[1];
        }

        out["q"] = info.accuracy;

        var when = info.when;
        out["ts"] = (when != null) ? when.value() : Time.now().value();

        if (info.altitude != null) { out["alt"] = info.altitude; }
        if (info.speed != null)    { out["spd"] = info.speed; }

        return out;
    }
}
