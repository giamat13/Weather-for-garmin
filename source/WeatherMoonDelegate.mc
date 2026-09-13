import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;

class WeatherMoonDelegate extends WatchUi.BehaviorDelegate {

    var view as WeatherMoonView;

    function initialize(view as WeatherMoonView) {
        BehaviorDelegate.initialize();
        self.view = view;
    }

    // Swipe left/right = move between the 4 screens (NOW / OUTLOOK / OUTFIT / MOON).
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        var dir = swipeEvent.getDirection();
        if (dir == WatchUi.SWIPE_LEFT) {
            view.nextScreen();
            return true;
        }
        if (dir == WatchUi.SWIPE_RIGHT) {
            view.prevScreen();
            return true;
        }
        return false;
    }

    // On the OUTLOOK screen, tapping a day column jumps to it and opens NOW.
    // On the NOW screen, tapping the day pill cycles the selected day.
    // Anywhere else, a tap just advances to the next screen.
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();

        if (view.screen == SCREEN_OUTLOOK) {
            var w = System.getDeviceSettings().screenWidth;
            var colW = w / 3;
            var day = (coords[0] / colW).toNumber();
            if (day < 0) { day = 0; }
            if (day > 2) { day = 2; }
            view.selectDay(day);
            view.goToScreen(SCREEN_NOW);
            return true;
        }

        if (view.screen == SCREEN_NOW && coords[1] < 34) {
            view.cycleDay();
            return true;
        }

        view.nextScreen();
        return true;
    }

    // Physical up/down buttons: change hour while on the NOW screen,
    // otherwise page between screens (useful on non-touch devices).
    function onNextPage() as Boolean {
        if (view.screen == SCREEN_NOW) {
            view.changeHour(1);
        } else {
            view.nextScreen();
        }
        return true;
    }

    function onPreviousPage() as Boolean {
        if (view.screen == SCREEN_NOW) {
            view.changeHour(-1);
        } else {
            view.prevScreen();
        }
        return true;
    }

    function onSelect() as Boolean {
        view.nextScreen();
        return true;
    }
}
