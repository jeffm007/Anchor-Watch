package com.nereus.anchorwatch

import android.content.Context
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import com.nereus.anchorwatch.core.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal enum class HazardKind(val title: String, val radius: Double) {
    ROCK("Rock", 8.0), SHOAL("Shoal", 15.0), DOCK("Dock or pier", 5.0), BOAT("Another boat", 30.0), OTHER("Other", 10.0)
}
internal data class Hazard(val id: String = UUID.randomUUID().toString(), val coordinate: Coordinate, val kind: HazardKind = HazardKind.ROCK, val radius: Double = kind.radius, val name: String = "", val hidden: Boolean = false) {
    val label get() = name.ifBlank { kind.title }
}
internal object Hazards {
    val marks = mutableStateListOf<Hazard>()
    var editing by mutableStateOf<Hazard?>(null)
    var dragOrigin by mutableStateOf<Hazard?>(null)
    private var loaded = false
    fun load(context: Context) {
        if (loaded) return
        loaded = true
        runCatching {
            val a = JSONArray(context.getSharedPreferences("watch", Context.MODE_PRIVATE).getString("hazards", "[]"))
            (0 until a.length()).mapNotNull { i -> runCatching { val j = a.getJSONObject(i)
                val radius = j.getDouble("radius"); require(radius.isFinite() && radius in 2.0..80.0)
                Hazard(j.getString("id"), Coordinate(j.getDouble("lat"), j.getDouble("lon")), HazardKind.valueOf(j.getString("kind")), radius, j.optString("name"), j.optBoolean("hidden"))
            }.getOrNull() }.forEach { marks.add(it) }
        }
    }
    fun save(context: Context) {
        val a = JSONArray(marks.map { JSONObject().put("id", it.id).put("lat", it.coordinate.latitude).put("lon", it.coordinate.longitude).put("kind", it.kind.name).put("radius", it.radius).put("name", it.name).put("hidden", it.hidden) })
        context.getSharedPreferences("watch", Context.MODE_PRIVATE).edit().putString("hazards", a.toString()).apply()
    }
    fun put(hazard: Hazard) { val i = marks.indexOfFirst { it.id == hazard.id }; if (i < 0) marks.add(hazard) else marks[i] = hazard }
    fun hideAll(context: Context) { marks.indices.forEach { marks[it] = marks[it].copy(hidden = true) }; save(context) }
}
@Composable
internal fun HazardEditor(context: Context) {
    val original = Hazards.editing ?: return
    var kind by remember(original.id) { mutableStateOf(original.kind) }
    var radius by remember(original.id) { mutableStateOf(original.radius.toFloat()) }
    var name by remember(original.id) { mutableStateOf(original.name) }
    val exists = Hazards.marks.any { it.id == original.id }
    AlertDialog(onDismissRequest = { Hazards.editing = null }, title = { Text(if (exists) "Edit hazard" else "Mark a hazard") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            HazardKind.entries.forEach { k -> TextButton(onClick = { kind = k; radius = k.radius.toFloat() }) { Text((if (kind == k) "✓ " else "") + k.title) } }
            Text("Keep off by ${meters(radius.toDouble())}")
            Slider(radius, { radius = it }, valueRange = 2f..80f, steps = 77)
            Text(if (kind == HazardKind.BOAT) "Allow for the other boat's own swing." else "How far around the mark to stay clear.")
            OutlinedTextField(name, { name = it.take(80) }, label = { Text("Name (optional)") })
            WatchSession.snapshot.anchor?.let { anchor ->
                val plan = WatchSession.scope
                if (plan != null) {
                val reach = plan.reach(WatchSession.monitor.rode) + plan.boatLength
                val gap = Geo.distance(anchor, original.coordinate) - radius - reach
                Text(if (gap <= 0) "Estimated stern swing reaches this hazard." else "Estimated stern swing clearance ${meters(gap)}.")
                Text("Based on entered rode, depth and boat length; verify clearance aboard.")
                } else Text("Enter depth and boat length in Anchor settings to estimate stern swing clearance.")
            }
            WatchSession.snapshot.fix?.let { Text("Boat to mark: ${meters(Geo.distance(it.coordinate, original.coordinate))}") }
            if (exists) TextButton(onClick = { Hazards.marks.removeAll { it.id == original.id }; Hazards.save(context); Hazards.editing = null }) { Text("Remove this hazard") }
        }
    }, confirmButton = { TextButton(onClick = { Hazards.put(original.copy(kind = kind, radius = radius.toDouble(), name = name, hidden = false)); Hazards.save(context); Hazards.editing = null }) { Text(if (exists) "Save" else "Mark it") } }, dismissButton = { TextButton(onClick = { Hazards.editing = null }) { Text("Cancel") } })
}
