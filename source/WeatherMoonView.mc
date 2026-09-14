import Toybox.WatchUi;
import Toybox.Application;
import Toybox.Graphics;
import Toybox.Communications;
import Toybox.Position;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.System;
import Toybox.Math;

// =====================================================================
//  WeatherMoonView — full UI rework
//  6 swipeable screens: NOW / HOURLY / OUTLOOK / OUTFIT / MOON & SUN / ALERTS
//  Every screen is laid out top-down using REAL measured font/element
//  heights (dc.getFontHeight, known circle radii, etc.) and accumulates
//  a running `y` cursor - exactly like the original app's safe pattern -
//  so nothing can ever overlap regardless of watch screen size.
// =====================================================================

const DAY_LABELS = ["Today", "Tomorrow", "Day after"] as Array<String>;
const WAKE_START_HOUR = 7;
const WAKE_END_HOUR = 21;


// screens
const SCREEN_NOW = 0;
const SCREEN_HOURLY = 1;
const SCREEN_OUTLOOK = 2;
const SCREEN_OUTFIT = 3;
const SCREEN_MOON = 4;
const SCREEN_ALERTS = 5;
const SCREEN_COUNT = 6;

// palette
const COLOR_BG = 0x0A1628;
const COLOR_CARD = 0x122438;
const COLOR_CARD_HI = 0x1B3552;
const COLOR_ACCENT = 0x3DDC97;
const COLOR_SUN = 0xFFB454;
const COLOR_RAIN = 0x5AA9E6;
const COLOR_TEXT_DIM = 0x7C93AD;
const COLOR_DOT_OFF = 0x24405C;

class WeatherMoonView extends WatchUi.View {

    var weatherData as Dictionary?;
    var loadError as Boolean = false;
    var errorCode as Number = 0;
    var loading as Boolean = true;

    var selectedOffset as Number = 0;
    var selectedHour as Number;
    var screen as Number = SCREEN_NOW;

    function initialize() {
        View.initialize();
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        selectedHour = now.hour;
    }

    function onShow() as Void {
        requestLocationAndWeather();
    }

    function requestLocationAndWeather() as Void {
        var lastFix = Position.getInfo();
        // Real devices return a non-null position (180,180) with QUALITY_NOT_AVAILABLE when there's no fix.
        if (lastFix != null && lastFix.position != null && lastFix.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            var pos = lastFix.position as Position.Location;
            var loc = pos.toDegrees();
            fetchWeather(loc[0].toDouble(), loc[1].toDouble());
        } else {
            // No fix yet (always the case in the simulator): show fallback now, refine when GPS arrives.
            // Fallback location from app settings (default Tel Aviv) until GPS arrives.
            fetchWeather(
                (Application.Properties.getValue("FallbackLat") as Numeric).toDouble(),
                (Application.Properties.getValue("FallbackLon") as Numeric).toDouble());
            Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onPosition));
        }
    }

    function onPosition(info as Position.Info) as Void {
        if (info.position != null && info.accuracy != Position.QUALITY_NOT_AVAILABLE) {
            var loc = (info.position as Position.Location).toDegrees();
            fetchWeather(loc[0].toDouble(), loc[1].toDouble());
        }
    }

    function fetchWeather(lat as Double, lon as Double) as Void {
        var url = "https://api.open-meteo.com/v1/forecast";
        var params = {
            "latitude" => lat,
            "longitude" => lon,
            "hourly" => "temperature_2m,weathercode,precipitation_probability,wind_speed_10m,wind_direction_10m,apparent_temperature",
            "daily" => "uv_index_max,sunset,sunrise",
            "timezone" => "auto",
            "forecast_days" => 3
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_URL_ENCODED },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        Communications.makeWebRequest(url, params, options, method(:onWeatherResponse));
    }

    function onWeatherResponse(responseCode as Number, data as Dictionary?) as Void {
        loading = false;
        System.println("weather response " + responseCode);
        if (responseCode == 200 && data != null) {
            weatherData = data;
            loadError = false;
        } else if (weatherData == null) {
            // keep showing earlier good data if a later (GPS-refined) fetch fails
            loadError = true;
            errorCode = responseCode;
        }
        WatchUi.requestUpdate();
    }

    // ---- navigation ----

    function cycleDay() as Void {
        selectedOffset = (selectedOffset + 1) % 3;
        WatchUi.requestUpdate();
    }

    function selectDay(offset as Number) as Void {
        selectedOffset = offset;
        WatchUi.requestUpdate();
    }

    function changeHour(delta as Number) as Void {
        selectedHour = ((selectedHour + delta) % 24 + 24) % 24;
        WatchUi.requestUpdate();
    }

    function nextScreen() as Void {
        screen = (screen + 1) % SCREEN_COUNT;
        WatchUi.requestUpdate();
    }

    function prevScreen() as Void {
        screen = (screen - 1 + SCREEN_COUNT) % SCREEN_COUNT;
        WatchUi.requestUpdate();
    }

    function goToScreen(s as Number) as Void {
        screen = s;
        WatchUi.requestUpdate();
    }

    // ---- data helpers ----

    function dayStartIndex(offset as Number) as Number {
        return offset * 24;
    }

    function hourlyIndex(offset as Number, hour as Number) as Number {
        return dayStartIndex(offset) + hour;
    }

    function dayStats(wd as Dictionary, offset as Number) as Dictionary {
        var hourly = wd.get("hourly") as Dictionary;
        var temps = hourly.get("temperature_2m") as Array;
        var codes = hourly.get("weathercode") as Array;
        var start = dayStartIndex(offset) + WAKE_START_HOUR;
        var count = WAKE_END_HOUR - WAKE_START_HOUR;

        var minT = 999.0;
        var maxT = -999.0;
        var hasRain = false;
        var hasSnow = false;
        for (var i = 0; i < count; i++) {
            var idx = start + i;
            if (idx >= temps.size()) { break; }
            var t = (temps[idx] as Numeric).toFloat();
            if (t < minT) { minT = t; }
            if (t > maxT) { maxT = t; }
            var c = (codes[idx] as Numeric).toNumber();
            if (WeatherLogic.isRainCode(c)) { hasRain = true; }
            if (WeatherLogic.isSnowCode(c)) { hasSnow = true; }
        }
        return {
            "minTemp" => minT, "maxTemp" => maxT,
            "hasRain" => hasRain, "hasSnow" => hasSnow
        };
    }

    // Bundles everything every screen needs for the currently selected
    // day/hour so onUpdate only computes it once per frame.
    function buildSnapshot(wd as Dictionary) as Dictionary {
        var idx = hourlyIndex(selectedOffset, selectedHour);
        var hourly = wd.get("hourly") as Dictionary;
        var temps = hourly.get("temperature_2m") as Array;
        var codes = hourly.get("weathercode") as Array;
        var precipProbArr = hourly.get("precipitation_probability") as Array?;
        var windSpeedArr = hourly.get("wind_speed_10m") as Array?;
        var windDirArr = hourly.get("wind_direction_10m") as Array?;
        var feelsArr = hourly.get("apparent_temperature") as Array?;
        var daily = wd.get("daily") as Dictionary;
        var uvMaxArr = daily.get("uv_index_max") as Array;
        var sunsetArr = daily.get("sunset") as Array;
        var sunriseArr = daily.get("sunrise") as Array?;

        var temp = Math.round((temps[idx] as Numeric).toFloat()).toNumber();
        var code = (codes[idx] as Numeric).toNumber();
        var uvMax = (uvMaxArr[selectedOffset] as Numeric).toFloat();
        var catLabel = WeatherLogic.categoryAndLabel(code);
        var category = catLabel[0] as String;
        var label = catLabel[1] as String;

        var precipProb = (precipProbArr != null && idx < precipProbArr.size())
            ? (precipProbArr[idx] as Numeric).toNumber() : 0;
        var windSpeed = (windSpeedArr != null && idx < windSpeedArr.size())
            ? Math.round((windSpeedArr[idx] as Numeric).toFloat()).toNumber() : 0;
        var windDirDeg = (windDirArr != null && idx < windDirArr.size())
            ? (windDirArr[idx] as Numeric).toFloat() : 0.0;
        var windDirLabel = WeatherLogic.windDirLabel(windDirDeg);
        var feelsLike = (feelsArr != null && idx < feelsArr.size())
            ? Math.round((feelsArr[idx] as Numeric).toFloat()).toNumber() : temp;

        // sunset/sunrise parsing: "YYYY-MM-DDTHH:MM"
        var sunsetStr = sunsetArr[selectedOffset] as String;
        var tIdx = sunsetStr.find("T") as Number;
        var timePart = sunsetStr.substring(tIdx + 1, sunsetStr.length()) as String;
        var sh = (timePart.substring(0, 2) as String).toNumber() as Number;
        var sm = (timePart.substring(3, 5) as String).toNumber() as Number;

        var riseH = 0;
        var riseM = 0;
        if (sunriseArr != null) {
            var sunriseStr = sunriseArr[selectedOffset] as String;
            var rIdx = sunriseStr.find("T") as Number;
            var risePart = sunriseStr.substring(rIdx + 1, sunriseStr.length()) as String;
            riseH = (risePart.substring(0, 2) as String).toNumber() as Number;
            riseM = (risePart.substring(3, 5) as String).toNumber() as Number;
        }

        var afterSunset = (selectedHour * 60) >= (sh * 60 + sm);
        var isSun = (category.equals("clear") || category.equals("pcloudy"));

        var stats = dayStats(wd, selectedOffset);
        var outfit = WeatherLogic.outfitFor(stats, uvMax);
        var moon = WeatherLogic.moonPhaseFor(selectedOffset);
        var alerts = WeatherLogic.alertsFor(wd, selectedOffset, selectedHour);

        return {
            "temp" => temp, "code" => code, "category" => category, "label" => label,
            "uvMax" => uvMax, "sh" => sh, "sm" => sm, "riseH" => riseH, "riseM" => riseM,
            "afterSunset" => afterSunset, "isSun" => isSun,
            "precipProb" => precipProb, "windSpeed" => windSpeed,
            "windDirLabel" => windDirLabel, "feelsLike" => feelsLike,
            "stats" => stats, "outfit" => outfit, "alerts" => alerts,
            "moonIdx" => moon[0] as Number, "moonName" => moon[1] as String
        };
    }

    function outfitRows(outfit as Dictionary) as Array<Dictionary> {
        var rows = [] as Array<Dictionary>;
        var shirtLong = outfit.get("shirtLong") as Boolean;
        var pantsLong = outfit.get("pantsLong") as Boolean;
        var sandals = outfit.get("sandals") as Boolean;
        var umbrella = outfit.get("umbrella") as Boolean;
        var coat = outfit.get("coat") as Boolean;
        var sweater = outfit.get("sweater") as Boolean;
        var sunscreen = outfit.get("sunscreen") as Boolean;

        rows.add({ "text" => (shirtLong ? "Long sleeves" : "Short sleeves"), "icon" => "shirt", "flag" => shirtLong });
        rows.add({ "text" => (pantsLong ? "Long pants" : "Short pants"), "icon" => "pants", "flag" => pantsLong });
        rows.add({ "text" => (sandals ? "Sandals ok" : "Closed shoes"), "icon" => "shoe", "flag" => sandals });
        if (umbrella) { rows.add({ "text" => "Bring an umbrella", "icon" => "umbrella", "flag" => false }); }
        if (coat) { rows.add({ "text" => "Wear a coat", "icon" => "coat", "flag" => false }); }
        if (sweater) { rows.add({ "text" => "Wear a sweater", "icon" => "sweater", "flag" => false }); }
        if (sunscreen) { rows.add({ "text" => "Use sunscreen", "icon" => "sunscreen", "flag" => false }); }
        return rows;
    }

    // =================================================================
    //  MAIN DRAW DISPATCH
    // =================================================================

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_WHITE, COLOR_BG);
        dc.clear();

        if (loading) {
            drawStatusScreen(dc, w, h, "Loading…", Graphics.COLOR_WHITE);
            return;
        }
        if (loadError || weatherData == null) {
            drawStatusScreen(dc, w, h, "Weather unavailable\n(" + errorCode + ")", Graphics.COLOR_RED);
            return;
        }

        var wd = weatherData as Dictionary;
        var snap = buildSnapshot(wd);

        // reserve the bottom strip for the page-dot indicator first,
        // so every screen's content area is defined *before* it draws.
        var dotsY = h - 10;
        var contentBottom = dotsY - 10;

        if (screen == SCREEN_NOW) {
            drawNowScreen(dc, w, h, contentBottom, snap);
        } else if (screen == SCREEN_HOURLY) {
            drawHourlyScreen(dc, w, h, contentBottom, wd);
        } else if (screen == SCREEN_OUTLOOK) {
            drawOutlookScreen(dc, w, h, contentBottom, wd);
        } else if (screen == SCREEN_OUTFIT) {
            drawOutfitScreen(dc, w, h, contentBottom, snap);
        } else if (screen == SCREEN_ALERTS) {
            drawAlertsScreen(dc, w, h, contentBottom, snap);
        } else {
            drawMoonScreen(dc, w, h, contentBottom, snap);
        }

        drawPageDots(dc, w, dotsY, screen);
    }

    function drawStatusScreen(dc as Graphics.Dc, w as Number, h as Number, msg as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h / 2, Graphics.FONT_MEDIUM, msg, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- shared chrome ----

    function drawPageDots(dc as Graphics.Dc, w as Number, y as Number, active as Number) as Void {
        var total = SCREEN_COUNT;
        var spacing = 10;
        var startX = (w / 2) - ((total - 1) * spacing / 2);
        for (var i = 0; i < total; i++) {
            var x = startX + (i * spacing);
            if (i == active) {
                dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, 3);
            } else {
                dc.setColor(COLOR_DOT_OFF, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, y, 2);
            }
        }
    }

    // Draws the day pill as the header of a screen and returns the y
    // just below it, so the caller's layout cursor stays accurate.
    function drawDayPill(dc as Graphics.Dc, cx as Number, topY as Number) as Number {
        var text = DAY_LABELS[selectedOffset];
        var font = Graphics.FONT_XTINY;
        var textH = dc.getFontHeight(font);
        var tw = dc.getTextWidthInPixels(text, font);
        var pillH = textH + 6;
        var pillW = tw + 40;
        dc.setColor(COLOR_CARD_HI, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - (pillW / 2), topY, pillW, pillH, pillH / 2);
        dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - (pillW / 2) + 9, topY + (pillH / 2)], [cx - (pillW / 2) + 14, topY + (pillH / 2) - 3], [cx - (pillW / 2) + 14, topY + (pillH / 2) + 3]]);
        dc.fillPolygon([[cx + (pillW / 2) - 9, topY + (pillH / 2)], [cx + (pillW / 2) - 14, topY + (pillH / 2) - 3], [cx + (pillW / 2) - 14, topY + (pillH / 2) + 3]]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, topY + (pillH / 2), font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        return topY + pillH;
    }

    function drawScreenTitle(dc as Graphics.Dc, cx as Number, topY as Number, title as String) as Number {
        var font = Graphics.FONT_XTINY;
        dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, topY, font, title.toUpper(), Graphics.TEXT_JUSTIFY_CENTER);
        return topY + dc.getFontHeight(font);
    }

    // =================================================================
    //  SCREEN 0 — NOW
    // =================================================================

    function drawNowScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, snap as Dictionary) as Void {
        var cx = w / 2;
        var category = snap.get("category") as String;
        var isSun = snap.get("isSun") as Boolean;
        var afterSunset = snap.get("afterSunset") as Boolean;
        var temp = snap.get("temp") as Number;
        var label = snap.get("label") as String;
        var feelsLike = snap.get("feelsLike") as Number;
        var windSpeed = snap.get("windSpeed") as Number;
        var windDirLabel = snap.get("windDirLabel") as String;
        var precipProb = snap.get("precipProb") as Number;

        // reserve the hour capsule at the very bottom of the content area first
        var hourFont = Graphics.FONT_XTINY;
        var hourText = (selectedHour < 10 ? "0" : "") + selectedHour.toString() + ":00";
        var capH = dc.getFontHeight(hourFont) + 6;
        var capY = bottom - capH;

        // reserve the feels-like/wind/rain info strip just above the capsule
        var infoFont = Graphics.FONT_XTINY;
        var infoH = dc.getFontHeight(infoFont) + 2;
        var infoY = capY - infoH - 2;

        var y = 4;
        y = drawDayPill(dc, cx, y);
        y += 6;

        // icon badge: size itself off the remaining space so it never
        // pushes into the info strip / hour capsule, however tall the screen is.
        var availableForBadge = infoY - y - 6;
        var badgeR = availableForBadge / 3;
        if (badgeR > 30) { badgeR = 30; }
        if (badgeR < 16) { badgeR = 16; }
        var badgeCy = y + badgeR;
        dc.setColor(COLOR_CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, badgeCy, badgeR);
        if (isSun && afterSunset) {
            drawMoonGlyph(dc, cx, badgeCy, snap.get("moonIdx") as Number, (badgeR * 0.65).toNumber());
        } else {
            drawWeatherGlyph(dc, cx, badgeCy, category, (badgeR * 0.65).toNumber());
        }
        y = badgeCy + badgeR + 4;

        var tempFont = Graphics.FONT_NUMBER_MEDIUM;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, tempFont, temp.toString() + "°", Graphics.TEXT_JUSTIFY_CENTER);
        y += dc.getFontHeight(tempFont) - 4;

        var labelFont = Graphics.FONT_XTINY;
        dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, labelFont, label, Graphics.TEXT_JUSTIFY_CENTER);

        // feels-like / wind / rain-chance strip (slot reserved above)
        var infoText = "Feels " + feelsLike.toString() + "° · " +
            windDirLabel + " " + windSpeed.toString() + "km/h · " +
            precipProb.toString() + "%";
        dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, infoY, infoFont, infoText, Graphics.TEXT_JUSTIFY_CENTER);

        // hour capsule (slot reserved above)
        dc.setColor(COLOR_CARD_HI, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - 34, capY, 68, capH, capH / 2);
        dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - 27, capY + (capH / 2)], [cx - 22, capY + (capH / 2) - 4], [cx - 22, capY + (capH / 2) + 4]]);
        dc.fillPolygon([[cx + 27, capY + (capH / 2)], [cx + 22, capY + (capH / 2) - 4], [cx + 22, capY + (capH / 2) + 4]]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, capY + (capH / 2), hourFont, hourText, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // =================================================================
    //  SCREEN 1 — HOURLY (temperature line + rain-chance bars)
    // =================================================================

    function drawHourlyScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, wd as Dictionary) as Void {
        var cx = w / 2;
        var y = 4;
        y = drawDayPill(dc, cx, y);
        y += 8;

        var hourly = wd.get("hourly") as Dictionary;
        var temps = hourly.get("temperature_2m") as Array;
        var precipProbArr = hourly.get("precipitation_probability") as Array?;

        var start = dayStartIndex(selectedOffset);
        var tVals = [] as Array<Float>;
        var pVals = [] as Array<Number>;
        var minT = 999.0;
        var maxT = -999.0;
        for (var i = 0; i < 24; i++) {
            var idx = start + i;
            if (idx >= temps.size()) { break; }
            var t = (temps[idx] as Numeric).toFloat();
            tVals.add(t);
            if (t < minT) { minT = t; }
            if (t > maxT) { maxT = t; }
            var p = 0;
            if (precipProbArr != null && idx < precipProbArr.size()) {
                p = (precipProbArr[idx] as Numeric).toNumber();
            }
            pVals.add(p);
        }
        if (maxT <= minT) { maxT = minT + 1.0; }

        var count = tVals.size();
        if (count < 2) {
            dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (y + bottom) / 2, Graphics.FONT_TINY, "No hourly data", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var axisFont = Graphics.FONT_XTINY;
        var axisH = dc.getFontHeight(axisFont);
        var chartBottom = bottom - axisH - 4;
        var chartTop = y;
        var chartH = chartBottom - chartTop;
        var barAreaH = chartH / 3;
        var lineAreaH = chartH - barAreaH - 4;
        var lineBottom = chartTop + lineAreaH;
        var barTop = lineBottom + 4;
        var barBottom = chartBottom;

        var x0 = 12;
        var stepX = (w - (x0 * 2)).toFloat() / (count - 1);

        // rain-chance bars
        dc.setColor(COLOR_RAIN, Graphics.COLOR_TRANSPARENT);
        var barW = stepX * 0.6;
        if (barW < 1.0) { barW = 1.0; }
        var barSpan = barBottom - barTop;
        for (var i = 0; i < count; i++) {
            var p = pVals[i] as Number;
            var bh = (barSpan * (p / 100.0)).toNumber();
            if (bh <= 0) { continue; }
            var bx = (x0 + (i * stepX) - (barW / 2)).toNumber();
            var by = barBottom - bh;
            dc.fillRectangle(bx, by, barW.toNumber(), bh);
        }

        // temperature line
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var prevX = 0;
        var prevY = 0;
        for (var i = 0; i < count; i++) {
            var t = tVals[i] as Float;
            var frac = (t - minT) / (maxT - minT);
            var px = (x0 + (i * stepX)).toNumber();
            var py = (lineBottom - (frac * lineAreaH)).toNumber();
            if (i > 0) {
                dc.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
        }
        // highlight the currently selected hour
        if (selectedHour < count) {
            var hx = (x0 + (selectedHour * stepX)).toNumber();
            var t2 = tVals[selectedHour] as Float;
            var frac2 = (t2 - minT) / (maxT - minT);
            var hy = (lineBottom - (frac2 * lineAreaH)).toNumber();
            dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(hx, hy, 3);
        }

        // hour-axis labels every 6 hours
        dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < count; i += 6) {
            var lx = (x0 + (i * stepX)).toNumber();
            var lbl = (i < 10 ? "0" : "") + i.toString();
            dc.drawText(lx, chartBottom + 2, axisFont, lbl, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // =================================================================
    //  SCREEN 2 — 3-DAY OUTLOOK
    // =================================================================

    function drawOutlookScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, wd as Dictionary) as Void {
        var cx = w / 2;
        var hourly = wd.get("hourly") as Dictionary;
        var codes = hourly.get("weathercode") as Array;
        var noonHour = 13;

        var y = 4;
        y = drawScreenTitle(dc, cx, y, "3-Day Outlook");
        y += 6;

        var colW = (w - 20) / 3;
        var cardTop = y;
        var cardH = bottom - cardTop;
        var labelFont = Graphics.FONT_XTINY;
        var labelH = dc.getFontHeight(labelFont);
        var glyphR = 12;
        var glyphCy = cardTop + labelH + 6 + glyphR;

        for (var d = 0; d < 3; d++) {
            var colCx = 10 + (colW * d) + (colW / 2);
            var stats = dayStats(wd, d);
            var minT = Math.round(stats.get("minTemp") as Float).toNumber();
            var maxT = Math.round(stats.get("maxTemp") as Float).toNumber();
            var idx = hourlyIndex(d, noonHour);
            var code = (codes[idx] as Numeric).toNumber();
            var catLabel = WeatherLogic.categoryAndLabel(code);
            var category = catLabel[0] as String;

            var isActive = (d == selectedOffset);
            dc.setColor(isActive ? COLOR_CARD_HI : COLOR_CARD, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(colCx - (colW / 2) + 4, cardTop, colW - 8, cardH, 10);
            if (isActive) {
                dc.setColor(COLOR_ACCENT, Graphics.COLOR_TRANSPARENT);
                dc.drawRoundedRectangle(colCx - (colW / 2) + 4, cardTop, colW - 8, cardH, 10);
            }

            dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
            var shortLabel = d == 0 ? "TODAY" : (d == 1 ? "TOMOR" : "DAY+2");
            dc.drawText(colCx, cardTop + 4, labelFont, shortLabel, Graphics.TEXT_JUSTIFY_CENTER);

            drawWeatherGlyph(dc, colCx, glyphCy, category, glyphR);

            var tempsY = glyphCy + glyphR + 6;
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCx, tempsY, labelFont, maxT.toString() + "°", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCx, tempsY + labelH, labelFont, minT.toString() + "°", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // =================================================================
    //  SCREEN 3 — OUTFIT
    // =================================================================

    function drawOutfitScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, snap as Dictionary) as Void {
        var cx = w / 2;
        var y = 4;
        y = drawDayPill(dc, cx, y);
        y += 4;

        var rows = outfitRows(snap.get("outfit") as Dictionary);
        var available = bottom - y;
        var count = rows.size() > 0 ? rows.size() : 1;
        var rowH = available / count;
        if (rowH > 44) { rowH = 44; }

        var totalContentH = rowH * rows.size();
        var startY = y + ((available - totalContentH) / 2);

        var font = rowH >= 32 ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var cardW = w - 24;
        var cardX0 = cx - (cardW / 2);
        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i] as Dictionary;
            var rowY = startY + (i * rowH);
            var rowCy = rowY + (rowH / 2);

            dc.setColor(COLOR_CARD, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(cardX0, rowY + 1, cardW, rowH - 3, 8);

            drawOutfitGlyph(dc, cardX0 + 20, rowCy, row.get("icon") as String, row.get("flag") as Boolean);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cardX0 + 38, rowCy, font, row.get("text") as String, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // =================================================================
    //  SCREEN 4 — MOON & SUN
    // =================================================================

    function drawMoonScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, snap as Dictionary) as Void {
        var cx = w / 2;
        var y = 4;
        y = drawDayPill(dc, cx, y);
        y += 6;

        // reserve the bottom info cards first, then size the moon badge
        // with whatever space is left above them. cardsH is derived from
        // the actual icon radius + two real text-line heights, not a
        // fixed guess, so the card content can never spill past its edge.
        var cardIconR = 8;
        var cardLabelFont = Graphics.FONT_XTINY;
        var cardLabelH = dc.getFontHeight(cardLabelFont);
        var cardsH = 4 + (cardIconR * 2) + 4 + cardLabelH + cardLabelH + 4;
        var cardsTop = bottom - cardsH;

        var nameFont = Graphics.FONT_XTINY;
        var nameH = dc.getFontHeight(nameFont);
        var availableForBadge = cardsTop - y - nameH - 8;
        var moonR = availableForBadge / 2;
        if (moonR > 28) { moonR = 28; }
        if (moonR < 14) { moonR = 14; }
        var moonCy = y + moonR;

        dc.setColor(COLOR_CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, moonCy, moonR);
        drawMoonGlyph(dc, cx, moonCy, snap.get("moonIdx") as Number, (moonR * 0.65).toNumber());

        var nameY = moonCy + moonR + 4;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, nameY, nameFont, snap.get("moonName") as String, Graphics.TEXT_JUSTIFY_CENTER);

        // sunrise + sunset + UV, three cards side by side in the reserved bottom row
        var gap = 4;
        var cardW = (w - (gap * 4)) / 3;
        var iconCy = cardsTop + 4 + cardIconR;
        var labelY = cardsTop + 4 + (cardIconR * 2) + 4;
        var valueY = labelY + cardLabelH;

        var col0 = gap;
        var col1 = gap + cardW + gap;
        var col2 = gap + cardW + gap + cardW + gap;

        var cardLayout = [cardsTop, cardW, cardsH, cardIconR, iconCy, labelY, valueY, cardLabelFont];

        var riseH = snap.get("riseH") as Number;
        var riseM = snap.get("riseM") as Number;
        var riseText = (riseH < 10 ? "0" : "") + riseH.toString() + ":" + (riseM < 10 ? "0" : "") + riseM.toString();
        drawInfoCard(dc, col0, cardLayout, "RISE", riseText, method(:drawSunsetGlyph));

        var sh = snap.get("sh") as Number;
        var sm = snap.get("sm") as Number;
        var sunsetText = (sh < 10 ? "0" : "") + sh.toString() + ":" + (sm < 10 ? "0" : "") + sm.toString();
        drawInfoCard(dc, col1, cardLayout, "SET", sunsetText, method(:drawSunsetGlyph));

        var uvMax = snap.get("uvMax") as Float;
        drawInfoCard(dc, col2, cardLayout, "UV", Math.round(uvMax).toNumber().toString(), method(:drawUvGlyph));
    }

    // Small reusable info-card drawer shared by the sunrise/sunset/UV cards.
    function drawInfoCard(dc as Graphics.Dc, x0 as Number, layout as Array,
        label as String, value as String, iconFn as Method) as Void {
        var top = layout[0] as Number;
        var cardW = layout[1] as Number;
        var cardH = layout[2] as Number;
        var iconR = layout[3] as Number;
        var iconCy = layout[4] as Number;
        var labelY = layout[5] as Number;
        var valueY = layout[6] as Number;
        var font = layout[7] as Graphics.FontDefinition;

        var colCx = x0 + (cardW / 2);
        dc.setColor(COLOR_CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x0, top, cardW, cardH, 10);
        iconFn.invoke(dc, colCx, iconCy, iconR);
        dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(colCx, labelY, font, label, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(colCx, valueY, font, value, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // =================================================================
    //  SCREEN 5 — ALERTS
    // =================================================================

    function drawAlertsScreen(dc as Graphics.Dc, w as Number, h as Number, bottom as Number, snap as Dictionary) as Void {
        var cx = w / 2;
        var y = 4;
        y = drawScreenTitle(dc, cx, y, "Alerts");
        y += 8;

        var alerts = snap.get("alerts") as Array<String>;
        if (alerts == null || alerts.size() == 0) {
            dc.setColor(COLOR_TEXT_DIM, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (y + bottom) / 2, Graphics.FONT_TINY, "No alerts right now",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var available = bottom - y;
        var rowH = available / alerts.size();
        if (rowH > 40) { rowH = 40; }
        var totalH = rowH * alerts.size();
        var startY = y + ((available - totalH) / 2);
        var font = rowH >= 30 ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var cardW = w - 24;
        var cardX0 = cx - (cardW / 2);

        for (var i = 0; i < alerts.size(); i++) {
            var rowY = startY + (i * rowH);
            var rowCy = rowY + (rowH / 2);
            dc.setColor(COLOR_CARD_HI, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(cardX0, rowY + 1, cardW, rowH - 3, 8);
            dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cardX0 + 16, rowCy, 4);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cardX0 + 30, rowCy, font, alerts[i] as String,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // =================================================================
    //  ICON PRIMITIVES — badge-friendly, scale by `r`
    //  (Connect IQ has no runtime SVG support — drawn with Dc primitives.)
    // =================================================================

    function drawWeatherGlyph(dc as Graphics.Dc, cx as Number, cy as Number, category as String, r as Number) as Void {
        if (category.equals("clear")) {
            drawSunGlyph(dc, cx, cy, r);
        } else if (category.equals("pcloudy")) {
            drawSunGlyph(dc, cx - (r / 3), cy - (r / 4), (r * 2) / 3);
            drawCloudGlyph(dc, cx + (r / 4), cy + (r / 4), r, COLOR_TEXT_DIM);
        } else if (category.equals("cloudy") || category.equals("fog")) {
            drawCloudGlyph(dc, cx, cy, r, Graphics.COLOR_LT_GRAY);
        } else if (category.equals("rain")) {
            drawCloudGlyph(dc, cx, cy - (r / 3), r, COLOR_TEXT_DIM);
            dc.setColor(COLOR_RAIN, Graphics.COLOR_TRANSPARENT);
            var dropR = r / 6;
            if (dropR < 2) { dropR = 2; }
            drawDrop(dc, cx - (r / 2), cy + (r / 2), dropR);
            drawDrop(dc, cx, cy + (r / 2) + dropR, dropR);
            drawDrop(dc, cx + (r / 2), cy + (r / 2), dropR);
        } else if (category.equals("snow")) {
            drawCloudGlyph(dc, cx, cy - (r / 3), r, COLOR_TEXT_DIM);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var flakeR = r / 4;
            drawSnowflakeGlyph(dc, cx - (r / 2), cy + (r / 2), flakeR);
            drawSnowflakeGlyph(dc, cx, cy + (r / 2) + flakeR, flakeR);
            drawSnowflakeGlyph(dc, cx + (r / 2), cy + (r / 2), flakeR);
        } else if (category.equals("storm")) {
            drawCloudGlyph(dc, cx, cy - (r / 3), r, Graphics.COLOR_DK_GRAY);
            dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
            drawBoltGlyph(dc, cx, cy + (r / 2), r / 2);
        }
    }

    function drawSunGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        var core = (r * 2) / 3;
        var rayLen = r / 2;
        for (var i = 0; i < 8; i++) {
            var angle = i * (Math.PI / 4.0);
            var innerX = cx + (core + 2) * Math.cos(angle);
            var innerY = cy + (core + 2) * Math.sin(angle);
            var outerX = cx + (core + 2 + rayLen) * Math.cos(angle);
            var outerY = cy + (core + 2 + rayLen) * Math.sin(angle);
            dc.drawLine(innerX, innerY, outerX, outerY);
        }
        dc.fillCircle(cx, cy, core);
    }

    function drawCloudGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var baseW = r * 1.7;
        var baseH = r / 2;
        dc.fillRoundedRectangle((cx - (baseW / 2)).toNumber(), cy, baseW.toNumber(), baseH.toNumber(), (baseH / 2).toNumber());
        dc.fillCircle((cx - (r / 2)).toNumber(), (cy - (r / 8)).toNumber(), (r / 2).toNumber());
        dc.fillCircle(cx, (cy - (r / 3)).toNumber(), (r / 1.7).toNumber());
        dc.fillCircle((cx + (r / 2)).toNumber(), (cy - (r / 10)).toNumber(), (r / 2.2).toNumber());
    }

    function drawDrop(dc as Graphics.Dc, x as Number, y as Number, size as Number) as Void {
        dc.fillPolygon([[x, y - size], [x - size, y + (size / 2)], [x + size, y + (size / 2)]]);
        dc.fillCircle(x, y + (size / 2), size);
    }

    function drawSnowflakeGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        for (var i = 0; i < 3; i++) {
            var angle = i * (Math.PI / 3.0);
            var dx = r * Math.cos(angle);
            var dy = r * Math.sin(angle);
            dc.drawLine(cx - dx, cy - dy, cx + dx, cy + dy);
        }
    }

    function drawBoltGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        var s = r / 10.0;
        dc.fillPolygon([
            [ (cx + 2 * s).toNumber(), (cy - 10 * s).toNumber() ],
            [ (cx - 6 * s).toNumber(), (cy + 2 * s).toNumber() ],
            [ (cx - 1 * s).toNumber(), (cy + 2 * s).toNumber() ],
            [ (cx - 4 * s).toNumber(), (cy + 14 * s).toNumber() ],
            [ (cx + 7 * s).toNumber(), (cy - 1 * s).toNumber() ],
            [ (cx + 1 * s).toNumber(), (cy - 1 * s).toNumber() ]
        ]);
    }

    function drawMoonGlyph(dc as Graphics.Dc, cx as Number, cy as Number, phaseIdx as Number, r as Number) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, r);
        if (phaseIdx == 0) {
            dc.setColor(COLOR_CARD_HI, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx, cy, r);
            return;
        }
        if (phaseIdx == 4) {
            return;
        }
        var waxing = phaseIdx < 4;
        var step = waxing ? (4 - phaseIdx) : (phaseIdx - 4);
        var shift = r - (step * (r / 4.0)).toNumber();
        dc.setColor(COLOR_CARD_HI, Graphics.COLOR_TRANSPARENT);
        if (waxing) {
            dc.fillCircle(cx - shift, cy, r);
        } else {
            dc.fillCircle(cx + shift, cy, r);
        }
    }

    function drawSunsetGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, r);
        dc.setColor(COLOR_CARD, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(cx - r, cy, r * 2, r);
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - r - 2, cy, cx + r + 2, cy);
    }

    function drawUvGlyph(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        var rayLen = r / 2;
        for (var i = 0; i < 8; i++) {
            var angle = i * (Math.PI / 4.0);
            var innerX = cx + (r / 2) * Math.cos(angle);
            var innerY = cy + (r / 2) * Math.sin(angle);
            var outerX = cx + (r / 2 + rayLen) * Math.cos(angle);
            var outerY = cy + (r / 2 + rayLen) * Math.sin(angle);
            dc.drawLine(innerX, innerY, outerX, outerY);
        }
        dc.drawCircle(cx, cy, r / 2);
    }

    function drawOutfitGlyph(dc as Graphics.Dc, cx as Number, cy as Number, icon as String, flag as Boolean) as Void {
        if (icon.equals("shirt")) {
            drawShirtGlyph(dc, cx, cy, flag);
        } else if (icon.equals("pants")) {
            drawPantsGlyph(dc, cx, cy, !flag);
        } else if (icon.equals("shoe")) {
            drawShoeGlyph(dc, cx, cy, flag);
        } else if (icon.equals("umbrella")) {
            drawUmbrellaGlyph(dc, cx, cy);
        } else if (icon.equals("coat")) {
            drawCoatGlyph(dc, cx, cy);
        } else if (icon.equals("sweater")) {
            drawSweaterGlyph(dc, cx, cy);
        } else if (icon.equals("sunscreen")) {
            drawSunscreenGlyph(dc, cx, cy);
        }
    }

    function drawShirtGlyph(dc as Graphics.Dc, cx as Number, cy as Number, longSleeves as Boolean) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - 5, cy - 6, 10, 12, 2);
        var sleeveLen = longSleeves ? 7 : 3;
        dc.fillPolygon([[cx - 5, cy - 6], [cx - 5 - sleeveLen, cy - 3], [cx - 5 - sleeveLen, cy], [cx - 5, cy - 2]]);
        dc.fillPolygon([[cx + 5, cy - 6], [cx + 5 + sleeveLen, cy - 3], [cx + 5 + sleeveLen, cy], [cx + 5, cy - 2]]);
    }

    function drawPantsGlyph(dc as Graphics.Dc, cx as Number, cy as Number, isShort as Boolean) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var legLen = isShort ? 4 : 9;
        dc.fillRectangle(cx - 5, cy - 7, 10, 4);
        dc.fillRectangle(cx - 5, cy - 3, 4, legLen);
        dc.fillRectangle(cx + 1, cy - 3, 4, legLen);
    }

    function drawShoeGlyph(dc as Graphics.Dc, cx as Number, cy as Number, sandal as Boolean) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (sandal) {
            dc.fillRoundedRectangle(cx - 7, cy + 1, 14, 3, 1);
            dc.drawLine(cx - 6, cy + 1, cx - 2, cy - 6);
            dc.drawLine(cx, cy + 1, cx + 1, cy - 6);
            dc.drawLine(cx + 6, cy + 1, cx + 3, cy - 6);
        } else {
            dc.fillPolygon([[cx - 7, cy + 4], [cx - 7, cy - 1], [cx - 2, cy - 3], [cx + 7, cy - 1], [cx + 7, cy + 4]]);
        }
    }

    function drawUmbrellaGlyph(dc as Graphics.Dc, cx as Number, cy as Number) as Void {
        dc.setColor(COLOR_RAIN, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[cx - 8, cy], [cx - 5, cy - 7], [cx - 2, cy - 9], [cx + 2, cy - 9], [cx + 5, cy - 7], [cx + 8, cy]]);
        dc.drawLine(cx, cy - 1, cx, cy + 7);
        dc.drawLine(cx, cy + 7, cx + 2, cy + 7);
    }

    function drawCoatGlyph(dc as Graphics.Dc, cx as Number, cy as Number) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - 6, cy - 7, 12, 14, 2);
        dc.fillPolygon([[cx - 6, cy - 7], [cx - 10, cy - 3], [cx - 10, cy + 3], [cx - 6, cy]]);
        dc.fillPolygon([[cx + 6, cy - 7], [cx + 10, cy - 3], [cx + 10, cy + 3], [cx + 6, cy]]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 2, cy - 7, cx, cy - 4);
        dc.drawLine(cx + 2, cy - 7, cx, cy - 4);
    }

    function drawSweaterGlyph(dc as Graphics.Dc, cx as Number, cy as Number) as Void {
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - 5, cy - 6, 10, 12, 2);
        dc.fillPolygon([[cx - 5, cy - 6], [cx - 9, cy - 3], [cx - 9, cy], [cx - 5, cy - 2]]);
        dc.fillPolygon([[cx + 5, cy - 6], [cx + 9, cy - 3], [cx + 9, cy], [cx + 5, cy - 2]]);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 2, cy - 6, cx, cy - 3);
        dc.drawLine(cx + 2, cy - 6, cx, cy - 3);
        dc.drawLine(cx - 5, cy + 5, cx + 5, cy + 5);
    }

    function drawSunscreenGlyph(dc as Graphics.Dc, cx as Number, cy as Number) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - 4, cy - 6, 8, 12, 2);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(cx - 1, cy - 9, 2, 3);
        dc.setColor(COLOR_SUN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx + 8, cy - 6, 3);
    }
}
