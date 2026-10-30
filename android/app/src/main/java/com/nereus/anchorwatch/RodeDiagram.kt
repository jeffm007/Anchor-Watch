package com.nereus.anchorwatch

import android.graphics.Paint
import android.graphics.Path
import android.graphics.DashPathEffect
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.nereus.anchorwatch.core.ScopeSettings
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.max

/** iOS-style side view with the modeled steady-load catenary when inputs are available. */
@Composable
internal fun RodeDiagram(scope: ScopeSettings, rode: Double) {
    val assessment = CalculationEngine.result?.assessment
    val wind = EnvironmentData.wind
    val depth = assessment?.let { it.height - scope.bowHeight } ?: (scope.depth + scope.tideRise)
    val description = "Anchoring side view: ${meters(rode)} of rode deployed, ${meters(depth)} water depth. Model estimate, not confirmation of holding."
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(Color(0xFF1C1C1E))) {
        Canvas(Modifier.fillMaxWidth().aspectRatio(1.65f).semantics { contentDescription = description }) {
            drawIntoCanvas { target ->
                val c = target.nativeCanvas
                val save = c.save()
                c.scale(size.width / 380f, size.height / 230f)
                val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
                fun color(value: Long) { p.color = value.toInt() }
                fun line(x: Float, y: Float, x2: Float, y2: Float, value: Long, width: Float = 1f) {
                    color(value); p.style = Paint.Style.STROKE; p.strokeWidth = width
                    c.drawLine(x, y, x2, y2, p)
                }
                fun path(value: Long, fill: Boolean = true, width: Float = 1f, block: Path.() -> Unit) {
                    color(value); p.style = if (fill) Paint.Style.FILL else Paint.Style.STROKE; p.strokeWidth = width
                    c.drawPath(Path().apply(block), p)
                }
                fun rect(x: Float, y: Float, x2: Float, y2: Float, value: Long, radius: Float = 0f) {
                    color(value); p.style = Paint.Style.FILL
                    c.drawRoundRect(x, y, x2, y2, radius, radius, p)
                }
                fun text(value: String, x: Float, y: Float, tint: Long, size: Float = 10f, right: Boolean = false) {
                    color(tint); p.style = Paint.Style.FILL; p.textSize = size
                    p.textAlign = if (right) Paint.Align.RIGHT else Paint.Align.LEFT
                    c.drawText(value, x, y, p)
                }
                fun arrow(y: Float, tint: Long, label: String) {
                    line(12f, y, 64f, y, tint, 1.5f)
                    line(58f, y - 3, 64f, y, tint, 1.5f); line(58f, y + 3, 64f, y, tint, 1.5f)
                    text(label, 71f, y + 3, tint)
                }
                val bottom = 197f
                val water = (bottom - (depth / max(scope.height + 4.0, 1.0) * 145).toFloat()).coerceIn(92f, 161f)
                val reach = assessment?.steadyShape?.reach ?: sqrt(max(0.0, rode * rode - scope.height * scope.height))
                val bowX = 44f + (320 * reach / max(reach + max(scope.boatLength, 5.0) * 1.8, 1.0)).toFloat()
                val bowY = water - (scope.bowHeight / max(scope.height + 4.0, 1.0) * 145).toFloat().coerceIn(0f, 38f)
                val anchorX = 44f
                // Blue water with a quiet wave edge, matching the iOS side-view palette.
                path(0xFF17344A) {
                    moveTo(0f, bottom)
                    for (i in 0..76) { val x = i * 5f; lineTo(x, water + sin(i * 0.75f) * 1.4f) }
                    lineTo(380f, bottom); close()
                }
                rect(0f, bottom, 380f, 230f, 0xFFCDB595)
                path(0xFFCDB595) { moveTo(10f, bottom); quadTo(20f, bottom - 10, 32f, bottom); close() }
                line(0f, bottom, 380f, bottom, 0xFF9C8062)

                // The full-extension line is geometric; the curved profile is illustrative.
                val canReach = rode >= (assessment?.height ?: scope.height)
                p.pathEffect = DashPathEffect(floatArrayOf(3f, 5f), 0f)
                path(0xB3FF9F0A, false, 1.2f) { moveTo(anchorX, bottom - 2); lineTo(bowX, bowY) }
                p.pathEffect = null
                text("Direct span", 144f, water + 21, 0xB3FF9F0A, 9f)
                path(if (canReach) 0xFFF2F2F7 else 0xFFFF453A, false, 2f) {
                    moveTo(anchorX, bottom - 2)
                    val shape = assessment?.steadyShape
                    if (shape != null && shape.reach > 0 && assessment.height > 0) {
                        shape.points.forEach { pt ->
                            lineTo(anchorX + (pt.x / shape.reach * (bowX - anchorX)).toFloat(),
                                bottom - 2 - (pt.y / assessment.height * (bottom - 2 - bowY)).toFloat())
                        }
                    } else cubicTo(anchorX + (bowX - anchorX) * 0.48f, bottom - 2, anchorX + (bowX - anchorX) * 0.76f, bottom - 8, bowX, bowY)
                }
                // Buried plough anchor and shackle.
                path(0xFF85858A, false, 3f) { moveTo(anchorX, bottom - 3); lineTo(23f, bottom + 4); lineTo(17f, bottom - 1) }
                path(0xFF77777C) { moveTo(16f, bottom - 2); lineTo(29f, bottom + 4); lineTo(10f, bottom + 7); close() }
                color(0xFF9A9A9F); p.style = Paint.Style.STROKE; p.strokeWidth = 1.5f
                c.drawCircle(anchorX, bottom - 3, 3f, p)
                rect(0f, bottom + 1, 65f, bottom + 10, 0x55CDB595)

                // Detailed trawler profile: bow left, white cabin and flybridge, navy hull.
                val boatWidth = (366f - bowX).coerceAtMost(155f)
                val boatSave = c.save()
                c.translate(bowX, water)
                c.scale(boatWidth / 142f, 1f)
                val freeboard = (water - bowY).coerceAtLeast(3f)
                val deck = -freeboard
                path(0xFF172252) {
                    moveTo(0f, deck); quadTo(3f, 5f, 23f, 10f)
                    lineTo(93f, 17f); lineTo(111f, 16f); lineTo(117f, 8f)
                    lineTo(139f, 5f); lineTo(142f, deck + 6f); lineTo(142f, deck + 2f)
                    quadTo(60f, deck + 3f, 0f, deck); close()
                }
                line(3f, 0f, 140f, 3f, 0xFFECECF0, 1.4f)
                line(0f, deck, 142f, deck + 2f, 0xFFB77B45, 1.7f)
                for (x in listOf(19f, 26f, 33f)) rect(x, deck + 5f, x + 3f, deck + 7f, 0xFFE2E2E7, 1f)
                val roof = deck - 25f
                path(0xFFF5F5F7) { moveTo(42f, deck); lineTo(38f, roof); lineTo(49f, roof + 1f); lineTo(136f, roof + 1f); lineTo(136f, roof + 5f); lineTo(123f, roof + 5f); lineTo(123f, deck + 2f); close() }
                line(135f, roof + 5, 135f, deck + 2, 0xFF96969C)
                path(0xFF202A38) { moveTo(42f, roof + 6f); lineTo(59f, roof + 6f); lineTo(59f, roof + 15f); lineTo(44f, roof + 15f); close() }
                for (x in listOf(65f, 82f, 99f)) rect(x, roof + 7f, x + 13f, roof + 15f, 0xFF202A38, 1.5f)
                path(0xFFF5F5F7) { moveTo(57f, roof); lineTo(62f, roof - 9f); lineTo(115f, roof - 9f); lineTo(115f, roof); close() }
                line(59f, roof - 2, 62f, roof - 9, 0xFF202A38, 2f)
                for (x in listOf(70f, 110f)) line(x, roof - 9, x, roof - 27, 0xFFA0A0A6)
                rect(64f, roof - 29f, 118f, roof - 26f, 0xFFF5F5F7, 2f)
                line(92f, roof - 29, 97f, roof - 42, 0xFFB0B0B6)
                line(97f, roof - 42, 98f, roof - 48, 0xFFB0B0B6)
                color(0xFFF5F5F7); p.style = Paint.Style.FILL
                c.drawOval(90f, roof - 44f, 102f, roof - 38f, p)
                rect(120f, roof - 5f, 135f, roof - 1f, 0xFFBDBDC2, 3f)
                line(2f, deck - 10f, 37f, deck - 9f, 0xFFA0A0A6)
                for (x in listOf(6f, 16f, 26f, 36f)) line(x, deck, x, deck - 10, 0xFFA0A0A6)
                c.restoreToCount(boatSave)
                arrow(17f, 0xFF98989F, wind?.let { "Wind ${it.speed.toInt()} G${it.gust.toInt()} kt" } ?: "Wind unavailable")
                text("${meters(rode, 0)} out", 8f, 221f, 0xFF53483D)
                text("${meters(depth)} deep", 372f, 221f, 0xFF53483D, right = true)
                c.restoreToCount(save)
            }
        }
        Text(if (assessment != null) "Modeled steady-load rode · ${meters(assessment.steadyShape.lying)} on bottom · not a holding test" else "Schematic · confirm depth and boat inputs for a catenary estimate", Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelSmall, color = Color.Gray)
    }
}
