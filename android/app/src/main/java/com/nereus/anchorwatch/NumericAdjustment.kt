package com.nereus.anchorwatch

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlin.math.round
import java.util.Locale

/** iOS-style inline decimal entry with a stepped slider; typed values retain precision. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NumericAdjustment(title: String, metersValue: Double, range: ClosedFloatingPointRange<Double>,
    feetStep: Double, metreStep: Double, unitOverride: String? = null, onChange: (Double) -> Unit) {
    val feet = WatchSession.useFeet
    val unit = unitOverride ?: lengthUnit
    val unitScale = if (unitOverride != null) 1.0 else if (feet) 1 / 0.3048 else 1.0
    val value = metersValue * unitScale
    val minimum = range.start * unitScale
    val maximum = range.endInclusive * unitScale
    val step = if (feet) feetStep else metreStep
    var focused by remember { mutableStateOf(false) }
    fun format(number: Double) = String.format(Locale.US, "%.2f", number).trimEnd('0').trimEnd('.')
    var draft by remember(feet) { mutableStateOf(format(value)) }
    val focusManager = LocalFocusManager.current
    LaunchedEffect(value, feet, focused) { if (!focused) draft = format(value) }
    fun commit() {
        val entered = draft.toDoubleOrNull()?.takeIf { it.isFinite() }
        if (entered != null) onChange(entered.coerceIn(minimum, maximum) / unitScale)
        draft = format(entered?.coerceIn(minimum, maximum) ?: value)
    }
    Column {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
            BasicTextField(draft, onValueChange = { draft = it }, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.merge(TextStyle(color = Color.White, textAlign = TextAlign.End)),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                modifier = Modifier.width(88.dp).padding(vertical = 8.dp).semantics { contentDescription = "$title in $unit" }
                    .onFocusChanged { state ->
                        if (focused && !state.isFocused) commit()
                        focused = state.isFocused
                    })
            Text(unit, color = Color.Gray, modifier = Modifier.padding(start = 8.dp))
        }
        Slider(value = value.toFloat().coerceIn(minimum.toFloat(), maximum.toFloat()),
            onValueChange = { raw ->
                focusManager.clearFocus()
                val stepped = (minimum + round((raw - minimum) / step) * step).coerceIn(minimum, maximum)
                onChange(stepped / unitScale)
            }, valueRange = minimum.toFloat()..maximum.toFloat(),
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = title },
            thumb = {
                Box(Modifier.size(28.dp, 20.dp).shadow(2.dp, RoundedCornerShape(12.dp))
                    .background(Color.White, RoundedCornerShape(12.dp)))
            },
            track = { state ->
                Canvas(Modifier.fillMaxWidth().height(5.dp)) {
                    val fraction = ((state.value - minimum) / (maximum - minimum)).toFloat().coerceIn(0f, 1f)
                    drawLine(Color(0xFF363638), Offset(0f, center.y), Offset(size.width, center.y), size.height,
                        cap = androidx.compose.ui.graphics.StrokeCap.Round)
                    drawLine(Color(0xFF009DFF), Offset(0f, center.y), Offset(size.width * fraction, center.y), size.height,
                        cap = androidx.compose.ui.graphics.StrokeCap.Round)
                }
            })
    }
}
