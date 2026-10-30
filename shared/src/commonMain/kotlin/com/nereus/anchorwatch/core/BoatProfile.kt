package com.nereus.anchorwatch.core

/** iOS-compatible profile inputs. SI: m, kg, L, m²; chain/rope diameter in mm. */
data class BoatProfile(
    val name: String = "Nereus",
    val waterlineLength: Double = 14.046,
    val beam: Double = 4.775,
    val draft: Double = 1.549,
    val displacement: Double = 28_122.73,
    val fuelCapacity: Double = 4_164.0,
    val waterCapacity: Double = 1_135.6,
    val holdingCapacity: Double = 242.3,
    val freeboard: Double = 1.676,
    val cabinHeight: Double = 2.743,
    val windageArea: Double? = null,
    val sideWindageArea: Double? = null,
    val anchorType: AnchorType = AnchorType.CLAW,
    val anchorWeight: Double = 49.9,
    val rodeType: RodeType = RodeType.ALL_CHAIN,
    val chainLength: Double = 91.44,
    val chainSize: Double = 9.525,
    val ropeLength: Double = 0.0,
    val ropeSize: Double = 0.0,
    val hasSnubber: Boolean = true,
    val snubberLength: Double = 6.096
) {
    init {
        require(listOf(waterlineLength, beam, draft, displacement, fuelCapacity, waterCapacity,
            holdingCapacity, freeboard, cabinHeight, anchorWeight, chainLength, chainSize,
            ropeLength, ropeSize, snubberLength).all { it.isFinite() && it >= 0 })
        require(listOfNotNull(windageArea, sideWindageArea).all { it.isFinite() && it >= 0 })
    }
    enum class AnchorType(val title: String) {
        NEW_GENERATION("New generation"), PLOW("Plow"), CLAW("Claw"), FLUKE("Fluke")
    }
    enum class RodeType(val title: String) {
        ALL_CHAIN("All chain"), CHAIN_AND_ROPE("Chain + rope"), ROPE("Rope");
        val hasChain get() = this != ROPE
        val hasRope get() = this != ALL_CHAIN
    }
    val loadedWeight get() = displacement + fuelCapacity * 0.85 + waterCapacity + holdingCapacity
    val estimatedWindage get() = beam * (freeboard + cabinHeight) * 0.8
    val frontWindage get() = windageArea?.takeIf { it > 0 } ?: estimatedWindage
    fun sideWindage(lengthOverall: Double) = sideWindageArea?.takeIf { it > 0 } ?: (lengthOverall * (freeboard + cabinHeight) * 0.8)
    val rodeCarried get() = (if (rodeType.hasChain) chainLength else 0.0) + (if (rodeType.hasRope) ropeLength else 0.0)
    val snubber get() = if (hasSnubber) snubberLength else 0.0
}
