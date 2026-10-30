package com.nereus.anchorwatch

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
import androidx.activity.result.contract.ActivityResultContracts

class MainActivity : ComponentActivity() {
    private val idleHandler = Handler(Looper.getMainLooper())
    private var blankView: View? = null
    private var idleBrightness: Float? = null
    private var consumeWakeGesture = false
    private var blankedBars: Pair<Boolean, Boolean>? = null
    private val dimDisplay = Runnable {
        idleBrightness = window.attributes.screenBrightness
        val current = idleBrightness ?: -1f
        window.attributes = window.attributes.apply {
            screenBrightness = if (current >= 0f) minOf(current, 0.05f) else 0.05f
        }
    }
    private val blankDisplay = Runnable {
        if (IdleDisplayPolicy.keepVisible(WatchSession.nightMode, WatchSession.keepNightDataVisible)) return@Runnable
        val insets = ViewCompat.getRootWindowInsets(window.decorView)
        blankedBars = (insets?.isVisible(WindowInsetsCompat.Type.statusBars()) ?: true) to
            (insets?.isVisible(WindowInsetsCompat.Type.navigationBars()) ?: true)
        WindowCompat.getInsetsController(window, window.decorView).hide(WindowInsetsCompat.Type.systemBars())
        blankView?.visibility = View.VISIBLE
        window.attributes = window.attributes.apply { screenBrightness = 0f }
    }
    private fun resetDisplayTimers() {
        idleHandler.removeCallbacks(dimDisplay)
        idleHandler.removeCallbacks(blankDisplay)
        blankView?.visibility = View.GONE
        blankedBars?.let { (status, navigation) ->
            val bars = WindowCompat.getInsetsController(window, window.decorView)
            if (status) bars.show(WindowInsetsCompat.Type.statusBars()) else bars.hide(WindowInsetsCompat.Type.statusBars())
            if (navigation) bars.show(WindowInsetsCompat.Type.navigationBars()) else bars.hide(WindowInsetsCompat.Type.navigationBars())
        }
        blankedBars = null
        idleBrightness?.let { value -> window.attributes = window.attributes.apply { screenBrightness = value } }
        idleBrightness = null
        idleHandler.postDelayed(dimDisplay, IdleDisplayPolicy.DIM_AFTER)
        idleHandler.postDelayed(blankDisplay, IdleDisplayPolicy.BLANK_AFTER)
    }
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            // The wake touch must not activate an unseen control beneath the black screen.
            consumeWakeGesture = blankView?.visibility == View.VISIBLE
            resetDisplayTimers()
            if (WatchSession.nightMode) window.attributes = window.attributes.apply { screenBrightness = 0.15f }
        }
        if (consumeWakeGesture) {
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) consumeWakeGesture = false
            return true
        }
        return super.dispatchTouchEvent(event)
    }
    override fun onResume() {
        super.onResume()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        resetDisplayTimers()
        if (WatchSession.nightMode) window.attributes = window.attributes.apply { screenBrightness = 0.15f }
    }
    override fun onPause() {
        resetDisplayTimers()
        idleHandler.removeCallbacksAndMessages(null)
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onPause()
    }
    override fun onDestroy() {
        idleHandler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (hasPermissions()) startGps() else WatchSession.error = "Precise location and notification permissions are required. You can enable them in Android Settings."
    }
    private fun hasPermissions() = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
        (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    private fun startGps() { if (WatchSession.simulation != null) return; runCatching { startForegroundService(Intent(this, MonitoringService::class.java)) }
        .onFailure { WatchSession.error = it.message ?: "Unable to start GPS." } }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WatchSession.load(this)
        setContent {
                LaunchedEffect(WatchSession.nightMode, WatchSession.keepNightDataVisible) {
                    resetDisplayTimers()
                    window.attributes = window.attributes.apply { screenBrightness = if (WatchSession.nightMode) 0.15f else -1f }
                }
                NereusApp(onStart = {
                    if (hasPermissions()) startGps() else permissions.launch(buildList {
                        add(Manifest.permission.ACCESS_FINE_LOCATION); add(Manifest.permission.ACCESS_COARSE_LOCATION)
                        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                    }.toTypedArray())
                }, onStop = { if (WatchSession.simulation != null) WatchSession.stopSimulation() else stopService(Intent(this, MonitoringService::class.java)) }, onSave = { WatchSession.save(this) }, onForget = { WatchSession.clearSaved(this) })
        }
        blankView = View(this).apply {
            setBackgroundColor(android.graphics.Color.BLACK)
            visibility = View.GONE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        addContentView(blankView, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }
}

