package com.nereus.anchorwatch

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color
import com.nereus.anchorwatch.core.*
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs

@Composable
internal fun BoatProfileScreen() {
    val context = LocalContext.current
    val b = SettingsStore.boat
    val scope = WatchSession.scope ?: WatchSession.boatGeometry
    val feet = WatchSession.useFeet
    val lengthScale = if (feet) 1 / 0.3048 else 1.0
    val weightScale = if (feet) 1 / 0.45359237 else 1.0
    val volumeScale = if (feet) 1 / 3.785411784 else 1.0
    val areaScale = if (feet) 1 / 0.09290304 else 1.0
    val weightUnit = if (feet) "lb" else "kg"
    val volumeUnit = if (feet) "gal" else "L"
    val areaUnit = if (feet) "ft²" else "m²"
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
        FormGroup {
            BasicTextField(b.name, { SettingsStore.updateBoat(b.copy(name = it.take(80))) }, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = Color.White),
                modifier = Modifier.fillMaxWidth().padding(vertical = 20.dp).semantics { contentDescription = "Boat name" })
        }
        FormSection("Hull") {
            FormGroup {
                FormNumber("Length overall", scope.boatLength, lengthUnit, lengthScale) { WatchSession.setBoatGeometry(context, scope.copy(boatLength = (it ?: 0.0).coerceAtMost(100.0))) }
                FormNumber("Waterline length", b.waterlineLength, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(waterlineLength = it!!)) }
                FormNumber("Beam", b.beam, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(beam = it!!)) }
                FormNumber("Draft", b.draft, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(draft = it!!)) }
                FormNumber("Dry weight", b.displacement, weightUnit, weightScale, divider = false) { SettingsStore.updateBoat(b.copy(displacement = it!!)) }
            }
        }
        FormSection("Tanks") {
            FormGroup {
                FormNumber("Fuel", b.fuelCapacity, volumeUnit, volumeScale) { SettingsStore.updateBoat(b.copy(fuelCapacity = it!!)) }
                FormNumber("Fresh water", b.waterCapacity, volumeUnit, volumeScale) { SettingsStore.updateBoat(b.copy(waterCapacity = it!!)) }
                FormNumber("Holding (blackwater)", b.holdingCapacity, volumeUnit, volumeScale) { SettingsStore.updateBoat(b.copy(holdingCapacity = it!!)) }
                FormRow(false) {
                    Text("Weight with full tanks", Modifier.weight(1f))
                    Text(NumberFormat.getNumberInstance(Locale.US).apply { maximumFractionDigits = 0 }.format(b.loadedWeight * weightScale) + " $weightUnit", color = Color.Gray)
                }
            }
        }
        FormSection("Windage") {
            FormGroup {
                FormNumber("Freeboard at the bow", b.freeboard, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(freeboard = it!!)) }
                FormNumber("Cabin above deck", b.cabinHeight, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(cabinHeight = it!!)) }
                FormNumber("Windage (Front)", b.frontWindage, areaUnit, areaScale, optional = true) { SettingsStore.updateBoat(b.copy(windageArea = it?.takeIf { n -> n > 0 })) }
                FormNumber("Windage (Side)", b.sideWindage(scope.boatLength), areaUnit, areaScale, optional = true, divider = false) { SettingsStore.updateBoat(b.copy(sideWindageArea = it?.takeIf { n -> n > 0 })) }
            }
            Text("Windage is estimated from the hull and cabin until you enter measured areas. Clear an area to use the estimate again.", color = Color.Gray, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp))
        }
        FormSection("Anchor") {
            FormGroup {
                ProfilePicker("Anchor type", b.anchorType.title, BoatProfile.AnchorType.entries.map { it.title }) {
                    SettingsStore.updateBoat(b.copy(anchorType = BoatProfile.AnchorType.entries[it]))
                }
                FormNumber("Anchor weight", b.anchorWeight, weightUnit, weightScale) { SettingsStore.updateBoat(b.copy(anchorWeight = it!!)) }
                FormNumber("Bow roller above water", scope.bowHeight, lengthUnit, lengthScale, divider = false) {
                    WatchSession.setBoatGeometry(context, scope.copy(bowHeight = (it ?: 0.0).coerceAtMost(30.0)))
                }
            }
        }
        FormSection("Rode") {
            FormGroup {
                FormRow {
                    FormSegments(BoatProfile.RodeType.entries.map { it.title }, b.rodeType.ordinal) {
                        SettingsStore.updateBoat(b.copy(rodeType = BoatProfile.RodeType.entries[it]))
                    }
                }
                if (b.rodeType.hasChain) {
                    FormNumber("Chain length", b.chainLength, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(chainLength = it!!)) }
                    SizePicker("Chain size", b.chainSize, true) { SettingsStore.updateBoat(b.copy(chainSize = it)) }
                }
                if (b.rodeType.hasRope) {
                    FormNumber("Rope length", b.ropeLength, lengthUnit, lengthScale) { SettingsStore.updateBoat(b.copy(ropeLength = it!!)) }
                    SizePicker("Rope size", b.ropeSize, false) { SettingsStore.updateBoat(b.copy(ropeSize = it)) }
                }
                FormToggle("Snubber or bridle", b.hasSnubber, {
                    SettingsStore.updateBoat(b.copy(hasSnubber = it, snubberLength = if (it && b.snubberLength == 0.0) 6.096 else b.snubberLength))
                }, divider = b.hasSnubber)
                if (b.hasSnubber) FormNumber("Snubber length", b.snubberLength, lengthUnit, lengthScale, divider = false) { SettingsStore.updateBoat(b.copy(snubberLength = it!!)) }
            }
        }
    }
}

@Composable
private fun ProfilePicker(title: String, current: String, values: List<String>, onSelect: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    FormRow {
        Text(title, Modifier.weight(1f))
        Box {
            TextButton(onClick = { open = true }) { Text("$current ⌄", color = Color.Gray) }
            DropdownMenu(open, onDismissRequest = { open = false }) {
                values.forEachIndexed { index, value -> DropdownMenuItem(text = { Text(value) }, onClick = { open = false; onSelect(index) }) }
            }
        }
    }
}
@Composable
private fun SizePicker(title: String, current: Double, chain: Boolean, onSelect: (Double) -> Unit) {
    val feet = WatchSession.useFeet
    val standard = if (feet) (if (chain) listOf(4, 5, 6, 7, 8, 10, 12) else listOf(6, 7, 8, 9, 10, 12, 14, 16)).map { it * 25.4 / 16 }
        else (if (chain) listOf(6, 7, 8, 10, 12, 13, 14, 16) else listOf(10, 12, 14, 16, 18, 20, 22, 24)).map { it.toDouble() }
    val sizes = listOf(0.0) + (if (current > 0 && standard.none { abs(it - current) < 0.01 }) standard + current else standard).sorted()
    fun label(mm: Double): String {
        if (mm == 0.0) return "Not set"
        if (!feet) return String.format(Locale.US, "%.1f mm", mm).replace(".0 mm", " mm")
        val sixteenths = kotlin.math.round(mm / 25.4 * 16).toInt()
        val whole = sixteenths / 16
        var n = sixteenths % 16; var d = 16
        while (n > 0 && n % 2 == 0) { n /= 2; d /= 2 }
        val approximate = if (abs(sixteenths / 16.0 * 25.4 - mm) > 0.1) "≈ " else ""
        return approximate + (if (whole > 0) "$whole " else "") + (if (n > 0) "$n/$d" else "") + " in"
    }
    ProfilePicker(title, label(current), sizes.map(::label)) { onSelect(sizes[it]) }
}
