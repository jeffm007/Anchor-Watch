package com.nereus.anchorwatch.calculations

import com.nereus.anchorwatch.core.*
import kotlin.math.*

/** Port of iOS AnchoringModel.swift. SI throughout; wind/current inputs in knots. */
data class AnchorConditions(val wind: Double = 15.0, val gust: Double = 25.0, val current: Double = 0.5,
    val waveHeight: Double = 0.3, val bottom: Bottom = Bottom.MUD, val direction: Direction = Direction.WITH,
    val rodeOut: Double = 45.0) {
    enum class Bottom(val title: String) { SAND("Sand"), MUD("Mud"), CLAY("Clay"), GRAVEL("Gravel/shell"), WEED("Weed"), ROCK("Rock") }
    enum class Direction(val title: String) { WITH("With wind"), ACROSS("Across"), AGAINST("Against") }
    init { require(listOf(wind, gust, current, waveHeight, rodeOut).all { it.isFinite() && it >= 0 }) }
}
data class ModelPoint(val x: Double, val y: Double)
data class RodeShape(val points: List<ModelPoint>, val lying: Double, val shankAngle: Double) { val reach get() = points.lastOrNull()?.x ?: 0.0 }
data class AnchorLoad(val wind: Double, val current: Double, val design: Double)
enum class ModelStatus { GOOD, MARGINAL, DANGER }
enum class ModelReason { NONE, RODE_TOO_SHORT, CHAIN_LIFTING, HOLDING }
data class AnchorAssessment(val height: Double, val load: AnchorLoad, val shape: RodeShape,
    val steadyLoad: AnchorLoad, val steadyShape: RodeShape, val liftOffLoad: Double?, val liftOffGust: Double?,
    val holding: Double?, val holdingGust: Double?, val safeGust: Double?, val rodeNeeded: Double?,
    val chainFriction: Double, val anchorLoad: Double, val status: ModelStatus, val reason: ModelReason)
object BoatMath {
    const val airDensity = 1.225
    fun windage(b: BoatProfile): Double? = b.windageArea?.takeIf { it > 0 } ?: b.estimatedWindage.takeIf { b.beam > 0 && b.freeboard > 0 }
    fun sideWindage(b: BoatProfile, length: Double): Double? = b.sideWindageArea?.takeIf { it > 0 } ?: b.sideWindage(length).takeIf { length > 0 && b.freeboard > 0 }
    fun windForce(area: Double, knots: Double) = 0.5 * airDensity * area * (knots * 0.514444).pow(2)
    fun windLoad(b: BoatProfile, knots: Double) = windage(b)?.let { windForce(it, knots) }
    fun deepestWater(b: BoatProfile, ratio: Double, bow: Double): Double? = if (b.rodeCarried > 0 && ratio > 0) max(0.0, b.rodeCarried / ratio - bow) else null
}
object AnchorMath {
    const val gravity = 9.81
    const val holdingSafety = 1.5
    const val rodeMargin = 1.15
    const val keelClearance = 0.6
    fun chainWeight(size: Double) = 0.022 * size * size * (1 - 1025.0 / 7850) * gravity
    fun holdingRatio(type: BoatProfile.AnchorType, bottom: AnchorConditions.Bottom): Double = when (bottom) {
        AnchorConditions.Bottom.SAND -> listOf(40.0, 20.0, 18.0, 50.0)
        AnchorConditions.Bottom.MUD -> listOf(25.0, 12.0, 10.0, 30.0)
        AnchorConditions.Bottom.CLAY -> listOf(30.0, 15.0, 15.0, 25.0)
        AnchorConditions.Bottom.GRAVEL -> listOf(15.0, 10.0, 10.0, 5.0)
        AnchorConditions.Bottom.WEED -> listOf(6.0, 4.0, 5.0, 2.0)
        AnchorConditions.Bottom.ROCK -> listOf(3.0, 3.0, 3.0, 3.0)
    }[type.ordinal]
    fun chainFriction(bottom: AnchorConditions.Bottom) = listOf(0.7, 0.5, 0.6, 0.75, 0.4, 0.5)[bottom.ordinal]
    fun chainNeeded(load: Double, height: Double, weight: Double) = if (weight > 0) sqrt(height * height + 2 * height * load / weight) else height
    fun lyingChain(length: Double, height: Double, load: Double, weight: Double) = if (weight > 0 && length > height) max(0.0, length - chainNeeded(load, height, weight)) else 0.0
    fun anchorLoad(load: Double, length: Double, height: Double, weight: Double, bottom: AnchorConditions.Bottom) =
        max(0.0, load - chainFriction(bottom) * weight * lyingChain(length, height, load, weight))
    fun angleEfficiency(degrees: Double) = max(0.1, 1 - degrees / 20)
    fun waveFactor(height: Double, snubber: Double) = 1 + height * if (snubber >= 5) 0.5 else 1.0
    fun currentLoad(b: BoatProfile, knots: Double) = 0.5 * 1025 * b.beam * b.draft * 0.6 * (knots * 0.514444).pow(2)
    fun load(b: BoatProfile, wind: Double, current: Double, wave: Double, area: Double? = null): AnchorLoad {
        val w = (area ?: BoatMath.windage(b))?.let { BoatMath.windForce(it, wind) } ?: 0.0
        val c = currentLoad(b, current)
        return AnchorLoad(w, c, (w + c) * 1.25 * waveFactor(wave, b.snubber))
    }
    fun gust(limit: Double, b: BoatProfile, current: Double, wave: Double, area: Double? = null): Double? {
        val a = (area ?: BoatMath.windage(b))?.takeIf { it > 0 } ?: return null
        val share = limit / (1.25 * waveFactor(wave, b.snubber)) - currentLoad(b, current)
        return if (share <= 0) 0.0 else sqrt(share / (0.5 * BoatMath.airDensity * a)) / 0.514444
    }
    fun liftOffLoad(length: Double, height: Double, weight: Double) = if (length > height && height > 0) weight * (length * length - height * height) / (2 * height) else 0.0
    fun deepestChainDepth(length: Double, load: Double, weight: Double, bow: Double): Double? {
        if (length <= 0 || weight <= 0 || load < 0 || bow < 0) return null
        val usable = length / rodeMargin; val a = load / weight
        return (usable * usable / (hypot(a, usable) + a) - bow).takeIf { it > 0 }
    }
    fun shape(length: Double, height: Double, load: Double, weight: Double, samples: Int = 40): RodeShape {
        require(listOf(length, height, load, weight).all { it.isFinite() && it >= 0 } && samples > 0)
        if (length <= height || height <= 0) return RodeShape(listOf(ModelPoint(0.0, max(0.0, height - length)), ModelPoint(0.0, height)), 0.0, 90.0)
        if (weight <= 0) { val reach = sqrt(length * length - height * height)
            return RodeShape(listOf(ModelPoint(0.0, 0.0), ModelPoint(reach, height)), 0.0, Math.toDegrees(atan2(height, reach))) }
        val a = max(load, 1.0) / weight
        val suspended = sqrt(height * height + 2 * a * height)
        if (suspended <= length) {
            val lying = length - suspended; val span = a * asinh(suspended / a)
            return RodeShape(listOf(ModelPoint(0.0, 0.0)) + (0..samples).map { val x = span * it / samples; ModelPoint(lying + x, a * (cosh(x / a) - 1)) }, lying, 0.0)
        }
        fun rise(u: Double) = a * (sqrt(1 + (u + length / a).pow(2)) - sqrt(1 + u * u))
        var lo = 0.0; var hi = 1.0
        while (rise(hi) < height && hi < 1e6) hi *= 2
        repeat(60) { val mid = (lo + hi) / 2; if (rise(mid) < height) lo = mid else hi = mid }
        val u = (lo + hi) / 2; val x0 = a * asinh(u); val x1 = a * asinh(u + length / a)
        return RodeShape((0..samples).map { val x = x0 + (x1 - x0) * it / samples; ModelPoint(x - x0, a * (cosh(x / a) - cosh(x0 / a))) }, 0.0, Math.toDegrees(atan(u)))
    }
    fun beamOnShare(wind: Double, current: Double, direction: AnchorConditions.Direction): Double {
        if (wind + current <= 0) return 0.0
        return when (direction) { AnchorConditions.Direction.WITH -> 0.0; AnchorConditions.Direction.ACROSS -> sin(atan2(current, wind)).pow(2); AnchorConditions.Direction.AGAINST -> (min(wind, current) / max(wind, current)).pow(2) }
    }
    fun windArea(b: BoatProfile, s: ScopeSettings, c: AnchorConditions): Double? {
        val front = BoatMath.windage(b) ?: return null
        val side = BoatMath.sideWindage(b, s.boatLength) ?: return front
        if (c.direction == AnchorConditions.Direction.WITH || c.current <= 0) return front
        return front + max(0.0, side - front) * beamOnShare(BoatMath.windForce(front, c.gust), currentLoad(b, c.current), c.direction)
    }
    fun assess(b: BoatProfile, s: ScopeSettings, c: AnchorConditions): AnchorAssessment {
        val h = s.height; val area = windArea(b, s, c)
        val load = load(b, c.gust, c.current, c.waveHeight, area)
        val allChain = b.rodeType == BoatProfile.RodeType.ALL_CHAIN || (b.rodeType == BoatProfile.RodeType.CHAIN_AND_ROPE && c.rodeOut <= b.chainLength)
        val weight = if (allChain && b.chainSize > 0) chainWeight(b.chainSize) else 0.0
        val shape = shape(c.rodeOut, h, load.design, weight)
        val steady = load(b, min(c.wind, c.gust), c.current, c.waveHeight, area)
        val steadyShape = shape(c.rodeOut, h, steady.design, weight)
        val lift = if (weight > 0) liftOffLoad(c.rodeOut, h, weight) else null
        val liftGust = lift?.let { gust(it, b, c.current, c.waveHeight, area) }
        val atAnchor = anchorLoad(load.design, c.rodeOut, h, weight, c.bottom)
        val fullHolding = (b.anchorWeight * gravity).takeIf { it > 0 }?.times(holdingRatio(b.anchorType, c.bottom))
        val holding = fullHolding?.times(angleEfficiency(shape.shankAngle))
        val holdingGust = fullHolding?.let { full ->
            fun within(g: Double): Boolean {
                val pull = load(b, g, c.current, c.waveHeight, area).design
                val angle = shape(c.rodeOut, h, pull, weight).shankAngle
                return anchorLoad(pull, c.rodeOut, h, weight, c.bottom) < full * angleEfficiency(angle) / holdingSafety
            }
            if (!within(0.0)) 0.0 else if (within(150.0)) 150.0 else {
                var lo = 0.0; var hi = 150.0
                repeat(50) { val mid = (lo + hi) / 2; if (within(mid)) lo = mid else hi = mid }; lo
            }
        }
        val safe = listOfNotNull(liftGust, holdingGust).minOrNull()
        val needed = if (weight > 0) chainNeeded(load.design, h, weight) * rodeMargin else null
        var status = ModelStatus.GOOD; var reason = ModelReason.NONE
        if (holding != null && atAnchor > holding / holdingSafety) { status = ModelStatus.MARGINAL; reason = ModelReason.HOLDING }
        if (shape.shankAngle > 0) { status = maxOf(status, ModelStatus.MARGINAL); if (reason == ModelReason.NONE) reason = ModelReason.CHAIN_LIFTING }
        if (holding != null && atAnchor > holding) { status = ModelStatus.DANGER; reason = ModelReason.HOLDING }
        if (shape.shankAngle >= 10) { status = ModelStatus.DANGER; reason = ModelReason.CHAIN_LIFTING }
        if (c.rodeOut <= h) { status = ModelStatus.DANGER; reason = ModelReason.RODE_TOO_SHORT }
        return AnchorAssessment(h, load, shape, steady, steadyShape, lift, liftGust, holding, holdingGust, safe, needed, load.design - atAnchor, atAnchor, status, reason)
    }
    fun suggestions(b: BoatProfile, s: ScopeSettings, c: AnchorConditions, r: AnchorAssessment, length: (Double) -> String): List<String> = buildList {
        if (c.rodeOut <= r.height) add("Rode does not reach the bottom at this tide. Review at least ${length(r.height * 3)} of rode.")
        r.rodeNeeded?.takeIf { it > c.rodeOut }?.let { needed ->
            if (b.rodeType.hasChain && needed > b.chainLength) {
                val deepest = deepestChainDepth(b.chainLength, r.load.design, chainWeight(b.chainSize), s.bowHeight)
                add(if (deepest != null && deepest > b.draft + keelClearance) "Carried chain cannot retain the modeled margin. Consider water under ${length(deepest)}, allowing for draft and low tide, or more shelter."
                    else "Carried chain needs water too shallow for adequate keel clearance at this load. Seek shelter or a longer rode.")
            } else add("Model needs ${length(needed - c.rodeOut)} more rode (${length(needed)} total) to retain chain on the bottom.")
        }
        if (r.shape.shankAngle > 0) add("Upward pull at %.0f° reduces modeled holding to %.0f%%.".format(r.shape.shankAngle, angleEfficiency(r.shape.shankAngle) * 100))
        if (r.holding != null && r.anchorLoad > r.holding / holdingSafety) add("Load approaches estimated holding in ${c.bottom.title.lowercase()}. Check the set and consider better ground or shelter.")
        if (c.bottom in listOf(AnchorConditions.Bottom.ROCK, AnchorConditions.Bottom.WEED)) add("${c.bottom.title} holding is unreliable. Verify the anchor set directly.")
        if (c.waveHeight >= 0.5 && b.snubber < 5) add("Use a suitable nylon snubber of at least ${length(6.0)} to reduce wave snatch.")
        if (c.current > 0 && c.direction != AnchorConditions.Direction.WITH) add("${c.direction.title} current can turn the boat beam-on. Loads include side windage; check chop and full swing.")
        if (c.current >= 1.5) add("Strong current may control the boat's heading when the wind eases.")
        if (b.draft > 0 && s.depth + s.tideRise < b.draft + keelClearance) add("Insufficient modeled keel clearance: ${length(s.depth + s.tideRise - b.draft)}. Check low water and actual depth.")
        if (isEmpty() || r.status == ModelStatus.GOOD) r.safeGust?.let { add("Estimated gust limit about ${it.toInt()} kt for these inputs. A model is not a holding test.") }
    }
}
