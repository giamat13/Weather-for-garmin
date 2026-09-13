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
