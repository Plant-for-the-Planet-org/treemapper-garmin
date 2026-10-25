import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The session screen: position going to TreeMapper, once a second, unattended.
//!
//! This screen is written for a watch nobody is holding. It is opened at the
//! plot, glanced at, and set down, so it answers the three questions a glance
//! actually asks:
//!
//!   1. Is it still running          -> LIVE or PAUSED, and the count climbing
//!   2. Is the phone getting it      -> the status line, always present
//!   3. Is the fix any good          -> the edge ring, and the quality word
//!
//! Point 2 is the deliberate reversal of the old rule. The capture screen only
//! warned when something broke, because somebody was looking at it while they
//! pressed a button. A watch left alone for an hour is the opposite situation:
//! a link that quietly died looks exactly like one that is working, so the
//! state is shown whether it is good news or not.
//!
//! The stream itself does not live here. SessionState owns the timer, so the
//! cadence survives this view going away and the screen going dark. All this
//! does is draw.

class StreamView extends WatchUi.View {

    //! Animation tick. 50 ms is the smallest interval Connect IQ accepts;
    //! anything lower is silently clamped and logs "Timer interval is too
    //! small" on every view change.
    private const FRAME_MS = 50;

    //! Resting rate. The screen only has to keep a seconds counter honest, and
    //! this app is meant to run all day with the receiver and the radio both
    //! working. Frames are the one cost here that can simply be refused.
    private const IDLE_MS = 1000;

    private var _layout as Layout or Null;
    private var _timer as Timer.Timer or Null;
    private var _rateMs as Number = IDLE_MS;

    private var _entered as Anim.Timeline;
    private var _toggled as Anim.Timeline;

    function initialize() {
        View.initialize();
        _entered = new Anim.Timeline(400);
        _toggled = new Anim.Timeline(450);
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _layout = new Layout(dc);
    }

    function onShow() as Void {
        _entered.start();
        setRate(FRAME_MS);
    }

    function onHide() as Void {
        stopTimer();
    }

    private function stopTimer() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    private function setRate(ms as Number) as Void {
        if (_timer != null and _rateMs == ms) { return; }
        stopTimer();
        _rateMs = ms;
        _timer = new Timer.Timer();
        _timer.start(method(:onFrame), ms, true);
    }

    function onFrame() as Void {
        var session = $.gSession;
        if (session == null) { return; }

        session.tick();

        var animating = _entered.isRunning() or _toggled.isRunning();
        setRate(animating ? FRAME_MS : IDLE_MS);

        WatchUi.requestUpdate();
    }

    //! Called by the delegate. Pause leaves the receiver on, so resuming is
    //! instant rather than another cold acquisition.
    function togglePause() as Void {
        var session = $.gSession;
        if (session == null) { return; }

        session.togglePause();
        _toggled = new Anim.Timeline(450);
        _toggled.start();

        setRate(FRAME_MS);
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var L = _layout;
        var session = $.gSession;
        if (L == null or session == null) { return; }

        dc.setColor(Theme.BG, Theme.BG);
        dc.clear();
        UiKit.smooth(dc, true);

        drawQualityRing(dc, L, session);

        var intro = Anim.easeOut(_entered.progress());
        if (session.isPaused()) {
            drawPaused(dc, L, session, intro);
        } else {
            drawLive(dc, L, session, intro);
        }

        drawStatus(dc, L, session);
        drawHints(dc, L, session, intro);
    }

    // ---- pieces -----------------------------------------------------------

    //! The ring carries fix quality, as it always has. While paused it drops
    //! to the inactive colour: the receiver is still running, but nothing on
    //! this screen should look like it is being sent anywhere.
    private function drawQualityRing(dc as Graphics.Dc, L as Layout,
                                     session as SessionState) as Void {
        if (session.isPaused()) {
            UiKit.ringSegments(dc, L.cx, L.cy, L.ringRadius, L.ringWidth,
                               session.quality, Theme.TEXT_FAINT, Theme.SURFACE);
            return;
        }

        var colour = Theme.quality(session.quality);

        // Below the warning threshold the ring breathes. This is the one
        // moment we actively want to pull the eye.
        if (session.quality < session.minQuality) {
            var b = 0.45 + (0.55 * Anim.breathe(System.getTimer(), 1400));
            colour = Theme.fade(Theme.quality(session.quality), b.toFloat());
        }

        UiKit.ringSegments(dc, L.cx, L.cy, L.ringRadius, L.ringWidth,
                           session.quality, colour, Theme.SURFACE);
    }

    private function drawLive(dc as Graphics.Dc, L as Layout,
                              session as SessionState, intro as Float) as Void {
        var fade = Anim.easeOut(_toggled.progress());

        UiKit.caption(dc, L.cx, L.topLabelY, "LIVE  " + session.intervalLabel(),
                      L.fontLabel,
                      Theme.blend(Theme.BG, Theme.GREEN_LIGHT, intro * fade));

        // The quality word is the hero. There is no metric accuracy to show:
        // Connect IQ reports Position.Quality and nothing else. fontTitle, not
        // fontHero, because the FONT_NUMBER_* faces carry digits only.
        UiKit.caption(dc, L.cx, (L.h * 0.40).toNumber(),
                      Theme.qualityLabel(session.quality), L.fontTitle,
                      Theme.blend(Theme.BG, Theme.quality(session.quality), intro));

        // The count is the proof that the session is alive. A number that is
        // climbing says more than any label can.
        UiKit.caption(dc, L.cx, (L.h * 0.505).toNumber(),
                      session.pointsSent().format("%d") + " sent", L.fontLabel,
                      Theme.blend(Theme.BG, Theme.TEXT_DIM, intro));
    }

    private function drawPaused(dc as Graphics.Dc, L as Layout,
                                session as SessionState, intro as Float) as Void {
        var fade = Anim.easeOut(_toggled.progress());

        UiKit.caption(dc, L.cx, L.topLabelY, "PAUSED", L.fontLabel,
                      Theme.blend(Theme.BG, Theme.TEXT_DIM, intro * fade));

        UiKit.caption(dc, L.cx, (L.h * 0.40).toNumber(), "PAUSED", L.fontTitle,
                      Theme.blend(Theme.BG, Theme.TEXT, intro));

        // Say that the receiver is still on, so nobody feels they have to
        // leave it running by not pausing.
        UiKit.caption(dc, L.cx, (L.h * 0.505).toNumber(), "receiver still warm",
                      L.fontLabel, Theme.blend(Theme.BG, Theme.TEXT_FAINT, intro));
    }

    //! Always drawn, good news or bad. See the note at the top of the file.
    private function drawStatus(dc as Graphics.Dc, L as Layout,
                                session as SessionState) as Void {
        UiKit.statusPill(dc, L.cx, L.statusY, session.streamStatus(),
                         session.streamColour(), L.fontLabel);
    }

    private function drawHints(dc as Graphics.Dc, L as Layout,
                               session as SessionState, intro as Float) as Void {
        UiKit.hairline(dc, L.cx, (L.h * 0.705).toNumber(),
                       (L.w * 0.30).toNumber(), Theme.HAIRLINE);

        var action = session.isPaused() ? "resume" : "pause";
        var primary = L.isTouch
            ? ("Tap to " + action)
            : ("START  " + action);

        UiKit.caption(dc, L.cx, L.bottomHintY, primary, L.fontBody,
                      Theme.blend(Theme.BG, Theme.GREEN_LIGHT, intro));

        UiKit.caption(dc, L.cx, L.secondHintY,
                      L.isTouch ? "Swipe back to end" : "BACK  end session",
                      L.fontLabel, Theme.blend(Theme.BG, Theme.TEXT_FAINT, intro));
    }
}

class StreamDelegate extends WatchUi.BehaviorDelegate {

    // Held directly rather than looked up with WatchUi.getCurrentView(), which
    // needs a newer API level than this app targets.
    private var _view as StreamView;

    function initialize(view as StreamView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.togglePause();
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        _view.togglePause();
        return true;
    }

    function onMenu() as Boolean {
        WatchUi.pushView(SessionMenu.build(), new SessionMenuDelegate(),
                         WatchUi.SLIDE_LEFT);
        return true;
    }

    //! Back ends the session, so it asks first.
    //!
    //! This screen is the whole app now, and the watch is meant to sit
    //! unattended on a stump or in a pocket for an hour at a time. One stray
    //! press should not quietly end a session that nobody is watching, and
    //! the user would not find out until they checked the phone.
    function onBack() as Boolean {
        WatchUi.pushView(
            new WatchUi.Confirmation("End session?"),
            new EndSessionDelegate(),
            WatchUi.SLIDE_UP);
        return true;
    }
}

class EndSessionDelegate extends WatchUi.ConfirmationDelegate {

    function initialize() {
        ConfirmationDelegate.initialize();
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            // AppBase.onStop runs on the way out and releases the receiver.
            System.exit();
        }
        return true;
    }
}
