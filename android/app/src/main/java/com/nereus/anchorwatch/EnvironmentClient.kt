package com.nereus.anchorwatch

import com.nereus.anchorwatch.core.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.json.JSONArray
import java.time.*
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit

internal data class WindHour(val time: Instant, val speed: Double, val gust: Double, val direction: Double)
internal data class TideStation(val id: String, val name: String, val coordinate: Coordinate, val canadian: Boolean = false)

/** Network/parsing layer shared by the app and opt-in live provider checks. */
internal class EnvironmentClient(private val client: OkHttpClient = OkHttpClient.Builder().callTimeout(25, TimeUnit.SECONDS).build()) {
    private suspend fun raw(url: String): String = withContext(Dispatchers.IO) {
        client.newCall(Request.Builder().url(url).header("User-Agent", "NereusAnchorWatch/${BuildConfig.VERSION_NAME}").build()).execute().use {
            check(it.isSuccessful) { "Provider returned HTTP ${it.code}" }
            it.body?.string() ?: error("Empty response")
        }
    }
    private suspend fun json(url: String) = JSONObject(raw(url))
    suspend fun weather(at: Coordinate, now: Instant = Instant.now()): Pair<WindHour, List<WindHour>> {
        val j = json("https://api.open-meteo.com/v1/forecast?latitude=${at.latitude}&longitude=${at.longitude}&current=wind_speed_10m,wind_gusts_10m,wind_direction_10m&hourly=wind_speed_10m,wind_gusts_10m,wind_direction_10m&wind_speed_unit=kn&timeformat=unixtime&timezone=UTC&forecast_days=3")
        val c = j.getJSONObject("current")
        fun row(o: JSONObject) = WindHour(Instant.ofEpochSecond(o.getLong("time")), o.getDouble("wind_speed_10m"), o.getDouble("wind_gusts_10m"), o.getDouble("wind_direction_10m"))
        val current = row(c)
        val h = j.getJSONObject("hourly"); val times = h.getJSONArray("time")
        return current to (0 until times.length()).map { i -> WindHour(Instant.ofEpochSecond(times.getLong(i)), h.getJSONArray("wind_speed_10m").getDouble(i), h.getJSONArray("wind_gusts_10m").getDouble(i), h.getJSONArray("wind_direction_10m").getDouble(i)) }
            .filter { it.time >= now.minusSeconds(3600) }.take(49)
    }
    suspend fun currents(at: Coordinate): CurrentResult {
        val stations = json("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=currentpredictions").getJSONArray("stations")
        val nearest = (0 until stations.length()).map { stations.getJSONObject(it) }
            .distinctBy { it.getString("id") }
            .minByOrNull { Geo.distance(at, Coordinate(it.getDouble("lat"), it.getDouble("lng"))) }
            ?: error("No NOAA current stations found")
        val distance = Geo.distance(at, Coordinate(nearest.getDouble("lat"), nearest.getDouble("lng")))
        check(distance <= 25_000) { "No NOAA current prediction station within 25 km. US coverage only." }
        val start = LocalDate.now(ZoneOffset.UTC).minusDays(1).format(DateTimeFormatter.BASIC_ISO_DATE)
        val j = json("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=currents_predictions&application=NereusAnchorWatch&station=${nearest.getString("id")}&begin_date=$start&range=96&interval=MAX_SLACK&units=english&time_zone=gmt&format=json")
        check(!j.has("error")) { j.optJSONObject("error")?.optString("message") ?: "Currents unavailable" }
        val rows = j.getJSONObject("current_predictions").getJSONArray("cp")
        val format = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
        val events = (0 until rows.length()).map { i -> val r = rows.getJSONObject(i)
            CurrentEvent(LocalDateTime.parse(r.getString("Time"), format).toInstant(ZoneOffset.UTC),
                r.getDouble("Velocity_Major"), r.getDouble("meanFloodDir"), r.getDouble("meanEbbDir")) }.sortedBy { it.time }
        check(events.size >= 2) { "No current predictions returned" }
        return CurrentResult(nearest.getString("name"), distance, events)
    }
    private var noaaStations: List<TideStation>? = null
    private var chsStations: List<TideStation>? = null
    suspend fun tides(at: Coordinate, now: Instant = Instant.now()): TideResult = supervisorScope {
        val noaa = async { capture { noaaStations ?: parseNoaaStations(json("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json?type=tidepredictions")).also { noaaStations = it } } }
        val chs = async { capture { if (at.latitude <= 41) emptyList() else chsStations ?: parseChsStations(JSONArray(raw("https://api-iwls.dfo-mpo.gc.ca/api/v1/stations"))).also { chsStations = it } } }
        val a = noaa.await(); val b = chs.await()
        val stations = a.getOrDefault(emptyList()) + b.getOrDefault(emptyList())
        check(stations.isNotEmpty()) { "Tide station catalogs unavailable. NOAA: ${a.exceptionOrNull()?.message}; CHS: ${b.exceptionOrNull()?.message}" }
        val nearest = stations.minBy { Geo.distance(at, it.coordinate) }
        val distance = Geo.distance(at, nearest.coordinate)
        check(distance <= 25_000) { "No tide prediction station within 25 km. Tide adjustment unavailable here." }
        val events = if (nearest.canadian) {
            val from = now.minusSeconds(24 * 3600).toString()
            val to = now.plusSeconds(4 * 24 * 3600).toString()
            parseChsEvents(JSONArray(raw("https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/${nearest.id}/data?time-series-code=wlp-hilo&from=$from&to=$to")))
        } else {
            val start = now.atZone(ZoneOffset.UTC).toLocalDate().minusDays(1).format(DateTimeFormatter.BASIC_ISO_DATE)
            val end = now.atZone(ZoneOffset.UTC).toLocalDate().plusDays(4).format(DateTimeFormatter.BASIC_ISO_DATE)
            parseNoaaEvents(json("https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions&application=NereusAnchorWatch&begin_date=$start&end_date=$end&station=${nearest.id}&datum=MLLW&time_zone=gmt&interval=hilo&units=metric&format=json"))
        }
        check(events.size >= 2 && WaterMath.height(now, events) != null && events.last().time >= now.plusSeconds(24 * 3600)) { "Tide predictions do not cover now and the next 24 hours." }
        TideResult(nearest.name + " (${nearest.id})", distance, events,
            if (nearest.canadian) "Canadian Hydrographic Service" else "NOAA",
            if (nearest.canadian) "chart datum" else "MLLW",
            if (a.isFailure || b.isFailure) "One station catalog is unavailable; nearest station selected from the available catalog." else null)
    }
    companion object {
        fun parseNoaaStations(j: JSONObject): List<TideStation> {
            val rows = j.getJSONArray("stations")
            return (0 until rows.length()).map { rows.getJSONObject(it) }.mapNotNull { r -> runCatching {
                TideStation(r.getString("id"), r.getString("name"), Coordinate(r.getDouble("lat"), r.getDouble("lng"))) }.getOrNull() }
        }
        fun parseChsStations(rows: JSONArray): List<TideStation> = (0 until rows.length()).map { rows.getJSONObject(it) }.mapNotNull { r -> runCatching {
            val series = r.optJSONArray("timeSeries") ?: return@runCatching null
            if ((0 until series.length()).none { series.getJSONObject(it).optString("code") == "wlp-hilo" }) return@runCatching null
            TideStation(r.getString("id"), r.getString("officialName"), Coordinate(r.getDouble("latitude"), r.getDouble("longitude")), true)
        }.getOrNull() }
        fun parseNoaaEvents(j: JSONObject): List<TidePrediction> {
            check(!j.has("error")) { j.optJSONObject("error")?.optString("message") ?: "Tides unavailable" }
            val rows = j.getJSONArray("predictions")
            val format = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
            return (0 until rows.length()).map { i -> val r = rows.getJSONObject(i)
                TidePrediction(LocalDateTime.parse(r.getString("t"), format).toInstant(ZoneOffset.UTC), r.getDouble("v"), r.getString("type") == "H") }.sortedBy { it.time }
        }
        fun parseChsEvents(rows: JSONArray): List<TidePrediction> {
            val sorted = (0 until rows.length()).map { rows.getJSONObject(it) }.map { Instant.parse(it.getString("eventDate")) to it.getDouble("value") }.sortedBy { it.first }
            if (sorted.size < 2) return emptyList()
            fun mean(parity: Int) = sorted.filterIndexed { i, _ -> i % 2 == parity }.map { it.second }.average()
            val highParity = if (mean(0) >= mean(1)) 0 else 1
            return sorted.mapIndexed { i, p -> TidePrediction(p.first, p.second, i % 2 == highParity) }
        }
    }
}
internal suspend fun <T> capture(block: suspend () -> T): Result<T> = try { Result.success(block()) } catch (e: CancellationException) { throw e } catch (e: Exception) { Result.failure(e) }
