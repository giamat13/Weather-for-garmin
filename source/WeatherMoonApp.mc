import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class WeatherMoonApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new WeatherMoonView();
        return [view, new WeatherMoonDelegate(view)];
    }
}
