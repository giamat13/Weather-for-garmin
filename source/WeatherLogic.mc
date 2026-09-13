import Toybox.Lang;
import Toybox.Math;
import Toybox.Time;

// Weather-code -> [category, label]. category drives which icon we draw.
// category: "clear" | "pcloudy" | "cloudy" | "fog" | "rain" | "snow" | "storm"
module WeatherLogic {

    const RAIN_CODES = [51, 53, 55, 61, 63, 65, 80, 81, 82, 95] as Array<Number>;
    const SNOW_CODES = [71, 73, 75] as Array<Number>;

    function categoryAndLabel(code as Number) as Array<String> {
        if (code == 0) { return ["clear", "Clear sky"]; }
        if (code == 1) { return ["pcloudy", "Mostly clear"]; }
        if (code == 2) { return ["pcloudy", "Partly cloudy"]; }
        if (code == 3) { return ["cloudy", "Cloudy"]; }
        if (code == 45 || code == 48) { return ["fog", "Fog"]; }
        if (code == 51 || code == 53 || code == 55) { return ["rain", "Drizzle"]; }
        if (code == 61 || code == 63 || code == 65) { return ["rain", "Rain"]; }
        if (code == 71 || code == 73) { return ["snow", "Snow"]; }
        if (code == 75) { return ["snow", "Heavy snow"]; }
        if (code == 80 || code == 81) { return ["rain", "Showers"]; }
        if (code == 82) { return ["storm", "Heavy showers"]; }
        if (code == 95) { return ["storm", "Thunderstorm"]; }
        return ["cloudy", "Weather"];
    }

    function isRainCode(code as Number) as Boolean {
        return RAIN_CODES.indexOf(code) != -1;
    }

    function isSnowCode(code as Number) as Boolean {
        return SNOW_CODES.indexOf(code) != -1;
    }

    function isStormCode(code as Number) as Boolean {
        return code == 82 || code == 95;
    }

    const WIND_DIRS = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
    ] as Array<String>;

    function windDirLabel(deg as Float) as String {
        var idx = Math.round(deg / 22.5).toNumber() % 16;
        if (idx < 0) { idx += 16; }
        return WIND_DIRS[idx];
    }

    // Looks a few hours ahead of the currently selected hour and flags
    // anything worth surfacing on the Alerts screen: a storm code that
    // isn't already active, a sharp temperature drop, or a high chance
    // of rain later in the day.
    function alertsFor(wd as Dictionary, offset as Number, currentHour as Number) as Array<String> {
        var alerts = [] as Array<String>;
        var hourly = wd.get("hourly") as Dictionary;
        var temps = hourly.get("temperature_2m") as Array;
        var codes = hourly.get("weathercode") as Array;
        var precipProbArr = hourly.get("precipitation_probability") as Array?;

        var curIdx = (offset * 24) + currentHour;
        if (curIdx >= temps.size()) { return alerts; }

        var curTemp = (temps[curIdx] as Numeric).toFloat();
        var curCode = (codes[curIdx] as Numeric).toNumber();
        var curStorm = isStormCode(curCode);

        var lookahead = 6;
        var stormFound = false;
        var minFutureTemp = curTemp;
        var highRainFound = false;
        for (var i = 1; i <= lookahead; i++) {
            var idx = curIdx + i;
            if (idx >= temps.size()) { break; }
            var c = (codes[idx] as Numeric).toNumber();
            if (!curStorm && isStormCode(c)) { stormFound = true; }
            var t = (temps[idx] as Numeric).toFloat();
            if (t < minFutureTemp) { minFutureTemp = t; }
            if (precipProbArr != null && idx < precipProbArr.size()) {
                var p = (precipProbArr[idx] as Numeric).toNumber();
                if (p >= 70) { highRainFound = true; }
            }
        }

        if (stormFound) {
            alerts.add("Storm expected within a few hours");
        }
        if ((curTemp - minFutureTemp) >= 6.0) {
            alerts.add("Sharp temperature drop ahead");
        }
        if (highRainFound) {
            alerts.add("High chance of rain later today");
        }
        return alerts;
    }

    // dayStats: {"minTemp"=>Float, "maxTemp"=>Float, "hasRain"=>Bool, "hasSnow"=>Bool}
    function outfitFor(dayStats as Dictionary, uvMax as Float) as Dictionary {
        var minTemp = dayStats.get("minTemp") as Float;
        var maxTemp = dayStats.get("maxTemp") as Float;
        var hasRain = dayStats.get("hasRain") as Boolean;
        var hasSnow = dayStats.get("hasSnow") as Boolean;

        var result = {} as Dictionary;
        result.put("shirtLong", minTemp < 20);
        result.put("pantsLong", minTemp < 22);
        result.put("sandals", (maxTemp >= 24) && !hasRain && !hasSnow);
        result.put("umbrella", hasRain);
        result.put("coat", (minTemp < 10) || hasSnow);
        result.put("sweater", (minTemp >= 10) && (minTemp < 16));
        result.put("sunscreen", uvMax >= 3);
        return result;
    }

    // Local moon-phase calculation - no network needed.
    // Returns [phaseIndex(0-7), phaseName]
    var MOON_PHASE_NAMES as Array<String> = [
        "New moon", "Waxing crescent", "First quarter", "Waxing gibbous",
        "Full moon", "Waning gibbous", "Last quarter", "Waning crescent"
    ];

    function moonPhaseFor(dayOffset as Number) as Array {
        var synodicMonth = 29.53058867;
        // known new moon: 2000-01-06 18:14 UTC, as Moment (seconds since 1970)
        var knownNewMoon = Time.Gregorian.moment({
            :year => 2000, :month => 1, :day => 6,
            :hour => 18, :minute => 14, :second => 0
        });
        var now = Time.now();
        var target = now.add(new Time.Duration(dayOffset * 86400));
        var diffSeconds = target.value() - knownNewMoon.value();
        var daysSince = diffSeconds / 86400.0;
        var age = daysSince - (Math.floor(daysSince / synodicMonth) * synodicMonth);
        if (age < 0) { age += synodicMonth; }
        var idx = (Math.round((age / synodicMonth) * 8).toNumber()) % 8;
        return [idx, MOON_PHASE_NAMES[idx]];
    }
}
