package com.nereus.anchorwatch

internal object IdleDisplayPolicy {
    const val DIM_AFTER = 30 * 60_000L
    const val BLANK_AFTER = 2 * 60 * 60_000L
    fun keepVisible(nightMode: Boolean, enabled: Boolean) = nightMode && enabled
}
