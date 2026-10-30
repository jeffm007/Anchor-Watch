package com.nereus.anchorwatch

import android.content.Context
import android.hardware.*
import androidx.compose.runtime.*
import com.nereus.anchorwatch.calculations.PressureTrend
import org.json.JSONArray
import org.json.JSONObject

/** The handset's barometer only: forecast pressure is never passed off as an onboard measurement. */
internal object PressureMonitor : SensorEventListener {
    val readings = mutableStateListOf<PressureTrend.Reading>()
    var available by mutableStateOf(false); private set
    private var manager: SensorManager? = null
    private var context: Context? = null
    private val owners = mutableSetOf<String>()
    fun start(c: Context, owner: String = "screen") {
        owners.add(owner)
        if (manager != null) return
        context = c.applicationContext
        if (readings.isEmpty()) runCatching {
            val rows = JSONArray(c.getSharedPreferences("pressure", Context.MODE_PRIVATE).getString("history", "[]"))
            (0 until rows.length()).map { rows.getJSONObject(it) }.map { PressureTrend.Reading(it.getLong("time"), it.getDouble("hPa")) }
                .filter { it.time >= System.currentTimeMillis() - 24 * 3600_000 && it.hPa in 800.0..1200.0 }.forEach(readings::add)
        }
        manager = c.getSystemService(SensorManager::class.java)
        val sensor = manager?.getDefaultSensor(Sensor.TYPE_PRESSURE)
        available = sensor != null
        if (sensor != null) manager?.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)
    }
    fun stop(owner: String = "screen") { owners.remove(owner); if (owners.isEmpty()) { manager?.unregisterListener(this); manager = null } }
    override fun onSensorChanged(event: SensorEvent) {
        val now = System.currentTimeMillis(); val pressure = event.values.firstOrNull()?.toDouble() ?: return
        if (pressure !in 800.0..1200.0 || readings.lastOrNull()?.let { now - it.time < 60_000 } == true) return
        readings.add(PressureTrend.Reading(now, pressure)); readings.removeAll { now - it.time > 24 * 3600_000 }
        context?.getSharedPreferences("pressure", Context.MODE_PRIVATE)?.edit()?.putString("history",
            JSONArray(readings.map { JSONObject().put("time", it.time).put("hPa", it.hPa) }).toString())?.apply()
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}
