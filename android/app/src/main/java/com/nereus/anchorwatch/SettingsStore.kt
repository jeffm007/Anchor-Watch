package com.nereus.anchorwatch

import android.content.Context
import androidx.compose.runtime.*
import com.nereus.anchorwatch.core.*
import org.json.JSONArray
import org.json.JSONObject

internal object SettingsStore {
    private var context: Context? = null
    var boat by mutableStateOf(BoatProfile()); private set
    var hideWarnings by mutableStateOf(true); private set
    var silenceAdvisories by mutableStateOf(true); private set
    var gustLimit by mutableIntStateOf(28); private set
    var trackEnabled by mutableStateOf(false); private set
    var tideWindowHours by mutableIntStateOf(12); private set
    var currentFactor by mutableDoubleStateOf(0.5); private set
    var log by mutableStateOf(emptyList<AnchorageEntry>()); private set
    private fun prefs() = context!!.getSharedPreferences("settings", Context.MODE_PRIVATE)
    fun load(at: Context) {
        if (context != null) return
        context = at.applicationContext
        val prefs = prefs()
        hideWarnings = prefs.getBoolean("hideWarnings", true)
        silenceAdvisories = prefs.getBoolean("silenceAdvisories", true)
        gustLimit = prefs.getInt("gustLimit", 28).coerceIn(10, 50)
        trackEnabled = prefs.getBoolean("trackEnabled", false)
        tideWindowHours = prefs.getInt("tideWindowHours", 12).takeIf { it in listOf(6, 12, 24) } ?: 12
        currentFactor = prefs.getFloat("currentFactor", 0.5f).toDouble().takeIf { it in listOf(1.0, 0.5, 0.25) } ?: 0.5
        val d = BoatProfile()
        boat = runCatching {
            val j = JSONObject(prefs.getString("boat", "{}")!!)
            fun n(key: String, fallback: Double) = j.optDouble(key, fallback).takeIf { it.isFinite() && it >= 0 } ?: fallback
            fun area(key: String) = j.optDouble(key).takeIf { it.isFinite() && it > 0 }
            d.copy(name = j.optString("name", d.name), waterlineLength = n("waterlineLength", d.waterlineLength),
                beam = n("beam", d.beam), draft = n("draft", d.draft), displacement = n("displacement", d.displacement),
                fuelCapacity = n("fuelCapacity", d.fuelCapacity), waterCapacity = n("waterCapacity", d.waterCapacity),
                holdingCapacity = n("holdingCapacity", d.holdingCapacity), freeboard = n("freeboard", d.freeboard),
                cabinHeight = n("cabinHeight", d.cabinHeight), windageArea = area("windageArea"), sideWindageArea = area("sideWindageArea"),
                anchorType = runCatching { BoatProfile.AnchorType.valueOf(j.getString("anchorType")) }.getOrDefault(d.anchorType),
                anchorWeight = n("anchorWeight", d.anchorWeight),
                rodeType = runCatching { BoatProfile.RodeType.valueOf(j.getString("rodeType")) }.getOrDefault(d.rodeType),
                chainLength = n("chainLength", d.chainLength), chainSize = n("chainSize", d.chainSize),
                ropeLength = n("ropeLength", d.ropeLength), ropeSize = n("ropeSize", d.ropeSize),
                hasSnubber = j.optBoolean("hasSnubber", d.hasSnubber), snubberLength = n("snubberLength", d.snubberLength))
        }.getOrDefault(d)
        if (!prefs.contains("boat")) updateBoat(boat)
        log = runCatching {
            val a = JSONArray(prefs.getString("log", "[]"))
            (0 until a.length()).mapNotNull { i -> runCatching {
                val j = a.getJSONObject(i)
                AnchorageEntry(j.getLong("started"), j.optLong("ended").takeIf { it > 0 }, Coordinate(j.getDouble("lat"), j.getDouble("lon")), j.getDouble("rode"), j.getDouble("radius"))
            }.getOrNull() }
        }.getOrDefault(emptyList())
    }
    fun updateBoat(value: BoatProfile) {
        boat = value
        val j = JSONObject().put("name", value.name).put("anchorType", value.anchorType.name)
            .put("rodeType", value.rodeType.name).put("hasSnubber", value.hasSnubber)
        mapOf("waterlineLength" to value.waterlineLength, "beam" to value.beam, "draft" to value.draft,
            "displacement" to value.displacement, "fuelCapacity" to value.fuelCapacity, "waterCapacity" to value.waterCapacity,
            "holdingCapacity" to value.holdingCapacity, "freeboard" to value.freeboard, "cabinHeight" to value.cabinHeight,
            "windageArea" to value.windageArea, "sideWindageArea" to value.sideWindageArea, "anchorWeight" to value.anchorWeight,
            "chainLength" to value.chainLength, "chainSize" to value.chainSize, "ropeLength" to value.ropeLength,
            "ropeSize" to value.ropeSize, "snubberLength" to value.snubberLength).forEach { (key, n) -> j.put(key, n ?: JSONObject.NULL) }
        prefs().edit().putString("boat", j.toString()).apply()
    }
    fun hideWarnings(value: Boolean) { hideWarnings = value; prefs().edit().putBoolean("hideWarnings", value).apply() }
    fun silenceAdvisories(value: Boolean) { silenceAdvisories = value; prefs().edit().putBoolean("silenceAdvisories", value).apply() }
    fun gustLimit(value: Int) { gustLimit = value.coerceIn(10, 50); prefs().edit().putInt("gustLimit", gustLimit).apply() }
    fun trackEnabled(value: Boolean) { trackEnabled = value; prefs().edit().putBoolean("trackEnabled", value).apply() }
    fun tideWindowHours(value: Int) { require(value in listOf(6, 12, 24)); tideWindowHours = value; prefs().edit().putInt("tideWindowHours", value).apply() }
    fun currentFactor(value: Double) { require(value in listOf(1.0, 0.5, 0.25)); currentFactor = value; prefs().edit().putFloat("currentFactor", value.toFloat()).apply() }
    fun dropped(at: Coordinate, rode: Double, radius: Double) {
        if (context == null) return
        ended()
        log = (listOf(AnchorageEntry(System.currentTimeMillis(), null, at, rode, radius)) + log).take(100)
        saveLog()
    }
    fun ended() {
        if (context == null) return
        log = log.map { if (it.ended == null) it.copy(ended = System.currentTimeMillis()) else it }
        saveLog()
    }
    private fun saveLog() {
        prefs().edit().putString("log", JSONArray(log.map { e -> JSONObject().put("started", e.started).put("ended", e.ended)
            .put("lat", e.coordinate.latitude).put("lon", e.coordinate.longitude).put("rode", e.rode).put("radius", e.radius) }).toString()).apply()
    }
    val gustAdvisory: String? get() {
        CalculationEngine.result?.hours?.filter { h -> h.time <= java.time.Instant.now().plusSeconds(12 * 3600) && h.safeGust?.let { h.gust > it } == true }
            ?.maxByOrNull { it.gust - (it.safeGust ?: 0.0) }?.let { return "Forecast gust ${it.gust.toInt()} kt exceeds modeled ${it.safeGust!!.toInt()} kt limit · ${localTime(it.time)}" }
        val gust = (EnvironmentData.forecast.filter { it.time <= java.time.Instant.now().plusSeconds(12 * 3600) }
            .map { it.gust } + listOfNotNull(EnvironmentData.wind?.gust)).maxOrNull() ?: return null
        return if (gust >= gustLimit) "Forecast gusts up to ${gust.toInt()} kt · warning set to $gustLimit kt" else null
    }
}
internal data class AnchorageEntry(val started: Long, val ended: Long?, val coordinate: Coordinate, val rode: Double, val radius: Double)
