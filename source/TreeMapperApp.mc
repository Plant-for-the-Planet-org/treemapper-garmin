import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! TreeMapper GPS for Garmin.
//!
//! A high accuracy GPS source for the TreeMapper phone app. The watch holds the
//! receiver, the phone holds everything else: species, measurements, photos,
//! auth, upload. See DESIGN.md.
//!
//! Session model: the receiver starts with the app and stops with it, and so
//! does the stream. The user opens this at the plot and sets it down, and the
//! watch posts its position to the phone every second until it is paused or
//! closed. Nothing has to be pressed per tree. See GpsService for why the
//! receiver has to stay warm, and SessionState for the stream itself.
class TreeMapperApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    //! Start the receiver, the phone link and the stream before any view
    //! exists, so the session is running by the time anything is on screen.
    //! When the phone launches this remotely with openApplication(), this is
    //! the first thing that runs.
    function onStart(state as Dictionary?) as Void {
        var session = new SessionState();
        $.gSession = session;
        session.startSession();
    }

    //! Release the receiver and stop the stream timer. Connect IQ does not do
    //! this for us, and a GNSS receiver left running is the difference between
    //! a working day and an afternoon.
    function onStop(state as Dictionary?) as Void {
        var session = $.gSession;
        if (session != null) {
            session.endSession();
        }
        $.gSession = null;
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new HomeView(), new HomeDelegate()];
    }
}
