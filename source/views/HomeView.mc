import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Opening screen.
//!
//! This is a short splash, not a decision. The receiver and the phone link
//! already started in AppBase.onStart, so there is nothing here to wait for and
//! nothing to confirm. It holds for a beat to say which app just opened, then
//! moves to acquisition on its own. START skips it.
//!
//! That matters for the field flow: the watch is opened, glanced at and set
//! down, so it has to reach the streaming screen without anyone touching it.
class HomeView extends WatchUi.View {

    const AUTO_ADVANCE_MS = 1500;

    private var _layout as Layout or Null;
    private var _timer as Timer.Timer or Null;
    private var _mark as WatchUi.BitmapResource or Null;
    private var _entered as Anim.Timeline;
    private var _shownAtMs as Number = 0;
    private var _moved as Boolean = false;

    function initialize() {
        View.initialize();
        _entered = new Anim.Timeline(600);
    }

    function onLayout(dc as Graphics.Dc) as Void {
        var L = new Layout(dc);
        _layout = L;
        // Loaded once. Loading a resource inside onUpdate is expensive.
        _mark = WatchUi.loadResource(L.markResource()) as WatchUi.BitmapResource;
    }

    function onShow() as Void {
        _moved = false;
        _shownAtMs = System.getTimer();
        _entered.start();
        _timer = new Timer.Timer();
        _timer.start(method(:onFrame), 60, true);
    }

    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    function onFrame() as Void {
        var session = $.gSession;
        if (session != null) {
            session.tick();
        }

        if ((System.getTimer() - _shownAtMs) >= AUTO_ADVANCE_MS) {
            advance();
            return;
        }
        WatchUi.requestUpdate();
    }

    function advance() as Void {
        if (_moved) { return; }
        _moved = true;
        WatchUi.switchToView(new AcquiringView(), new AcquiringDelegate(),
                             WatchUi.SLIDE_IMMEDIATE);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var L = _layout;
        if (L == null) { return; }

        dc.setColor(Theme.BG, Theme.BG);
        dc.clear();
        UiKit.smooth(dc, true);

        var intro = Anim.easeOut(_entered.progress());
        var now = System.getTimer();

        // A halo that breathes slowly behind the mark, so the screen is not a
        // flat black field.
        var haloR = (L.r * 0.48 * (0.96 + 0.04 * Anim.breathe(now, 4200))).toNumber();
        dc.setPenWidth(2);
        dc.setColor(Theme.blend(Theme.BG, Theme.GREEN, 0.60 * intro),
                    Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(L.cx, (L.h * 0.355).toNumber(), haloR);

        var mark = _mark;
        if (mark != null) {
            UiKit.bitmapCentred(dc, L.cx, (L.h * 0.355).toNumber(), mark);
        }

        UiKit.caption(dc, L.cx, (L.h * 0.63).toNumber(), "TREEMAPPER",
                      L.fontTitle, Theme.blend(Theme.BG, Theme.TEXT, intro));
        UiKit.caption(dc, L.cx, (L.h * 0.72).toNumber(), "GPS companion",
                      L.fontLabel, Theme.blend(Theme.BG, Theme.TEXT_FAINT, intro));

        UiKit.caption(dc, L.cx, L.bottomHintY, "starting receiver", L.fontLabel,
                      Theme.blend(Theme.BG, Theme.GREEN_LIGHT, intro * 0.85));
    }
}

//! Home input. The only thing to do here is skip the wait.
class HomeDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() as Boolean {
        WatchUi.switchToView(new AcquiringView(), new AcquiringDelegate(),
                             WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return onSelect();
    }
}
