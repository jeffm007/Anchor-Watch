package com.nereus.anchorwatch

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.*
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.*
import kotlinx.coroutines.*
import java.time.Instant
import com.nereus.anchorwatch.core.*

class MonitoringService : Service(), LocationListener {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var locations: LocationManager
    private var wakeLock: PowerManager.WakeLock? = null
    private var tone: ToneGenerator? = null
    private var lastTone = 0L
    private var started = false
    private var simulationSession = false
    private var simulationTick = 0L
    private var lastNotification = ""
    private var notificationTime = 0L
    private val environmentScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var weatherAttempt = Long.MIN_VALUE
    private var weatherLocation: Coordinate? = null
    private fun refreshEnvironment() {
        val s = WatchSession.snapshot
        val at = s.anchor ?: s.fix?.takeIf { WatchSession.now() - it.time in 0..15_000 }?.coordinate ?: return
        val moved = weatherLocation?.let { Geo.distance(it, at) > 1_000 } ?: true
        if (!EnvironmentData.loading && (moved || SystemClock.elapsedRealtime() - weatherAttempt >= 15 * 60_000L)) {
            weatherAttempt = SystemClock.elapsedRealtime()
            weatherLocation = at
            environmentScope.launch { EnvironmentData.fetch(at) }
        }
    }
    private val watchdog = object : Runnable {
        override fun run() {
            if (simulationSession && WatchSession.simulation == null) { stopSelf(); return }
            if (simulationSession) {
                val now = SystemClock.elapsedRealtime()
                WatchSession.simulationStep(((now - simulationTick) / 1000.0).coerceIn(0.0, 1.0))
                simulationTick = now
            }
            if (!simulationSession && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                WatchSession.error = "Precise GPS unavailable. Monitoring stopped; restore location access and resume."
                stopSelf(); return
            }
            if (!simulationSession && !locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                WatchSession.error = "GPS disabled. Restore location immediately; position monitoring is interrupted."
                WatchSession.monitor.gpsUnavailable(WatchSession.now())
            }
            // Renew only after expiry; a stalled service cannot hold the CPU awake indefinitely.
            if (wakeLock?.isHeld == false) wakeLock?.acquire(10 * 60 * 1_000L)
            if (!simulationSession) WatchSession.publish()
            val alarm = WatchSession.snapshot.alarm
            if (!simulationSession && alarm != null && WatchSession.now() - lastTone >= 2_000) {
                try {
                    if (tone == null) tone = ToneGenerator(AudioManager.STREAM_ALARM, 100)
                    if (tone?.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 1_000) != true)
                        WatchSession.audioError = "Siren could not start."
                } catch (_: RuntimeException) { WatchSession.audioError = "Siren unavailable on this audio route." }
                lastTone = WatchSession.now()
            } else if (alarm == null) tone?.stopTone()
            refreshEnvironment()
            val summary = lockScreenSummary()
            val text = summary.expanded
            // Distance can change every fix. Update silently at most once per five seconds,
            // while alarm/status changes are reflected immediately.
            if (text != lastNotification && (SystemClock.elapsedRealtime() - notificationTime >= 5_000 ||
                        text.substringBefore('\n') != lastNotification.substringBefore('\n'))) {
                getSystemService(NotificationManager::class.java).notify(1, notification(summary))
                lastNotification = text
                notificationTime = SystemClock.elapsedRealtime()
            }
            handler.postDelayed(this, if (simulationSession) 200 else 1_000)
        }
    }
    override fun onCreate() {
        super.onCreate()
        locations = getSystemService(LocationManager::class.java)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel("anchor_status_v2", "Anchor status on lock screen", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Live anchor distance, circle monitoring status, and estimated wind"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
        )
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (started && simulationSession && WatchSession.simulation == null) {
            handler.removeCallbacks(watchdog)
            if (wakeLock?.isHeld == true) wakeLock?.release()
            WatchSession.simulationServiceRunning = false
            started = false
        }
        if (started) return START_NOT_STICKY
        simulationSession = WatchSession.simulation != null
        try {
            if (!simulationSession) check(checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED) { "Precise location permission is required." }
            if (!simulationSession) check(locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) { "Turn on GPS location, then try again." }
            if (Build.VERSION.SDK_INT >= 33) check(checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) { "Allow notifications before monitoring." }
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, notification(LockScreenSummary("Acquiring GPS", "Anchor distance: —", "Wind estimate: unavailable")), if (simulationSession) { if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0 } else ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(1, notification(LockScreenSummary("Acquiring GPS", "Anchor distance: —", "Wind estimate: unavailable")))
            wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Nereus:AnchorMonitor").apply { acquire(10 * 60 * 1_000L) }
            if (!simulationSession) WatchSession.monitor.resetMeasurements()
            // The main-thread callback and monotonic timestamps avoid clock-change/ordering errors.
            if (!simulationSession) locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1_000L, 0f, this, Looper.getMainLooper())
            PressureMonitor.start(this, "monitor")
            started = true
            simulationTick = SystemClock.elapsedRealtime()
            WatchSession.simulationServiceRunning = simulationSession
            WatchSession.running = true
            WatchSession.error = null
            handler.post(watchdog)
        } catch (e: Exception) {
            WatchSession.error = e.message ?: "Could not start location monitoring."
            stopSelf()
        }
        // Never silently recover a session with stale positions after process death.
        return START_NOT_STICKY
    }
    override fun onLocationChanged(location: Location) {
        if (WatchSession.simulation != null || !location.hasAccuracy()) return
        WatchSession.gpsSpeed = if (location.hasSpeed()) location.speed.toDouble() else null
        WatchSession.gpsCourse = if (location.hasBearing()) location.bearing.toDouble() else null
        val measurement = location.elapsedRealtimeNanos / 1_000_000
        runCatching {
            if (WatchSession.monitor.accept(Fix(Coordinate(location.latitude, location.longitude), location.accuracy.toDouble(), measurement), WatchSession.now())) WatchSession.error = null
            WatchSession.publish()
        }
    }
    override fun onProviderDisabled(provider: String) {
        if (WatchSession.simulation != null) return
        WatchSession.error = "GPS disabled. Position monitoring interrupted."
        WatchSession.monitor.gpsUnavailable(WatchSession.now())
        WatchSession.publish()
    }
    override fun onDestroy() {
        environmentScope.cancel()
        PressureMonitor.stop("monitor")
        handler.removeCallbacksAndMessages(null)
        runCatching { locations.removeUpdates(this) }
        tone?.release(); tone = null
        if (wakeLock?.isHeld == true) wakeLock?.release()
        WatchSession.simulationServiceRunning = false
        if (simulationSession || WatchSession.simulation != null) { super.onDestroy(); return }
        WatchSession.running = false
        // Preserve saved anchor for explicit recovery, but never display Holding while stopped.
        WatchSession.monitor.raise()
        WatchSession.publish()
        super.onDestroy()
    }
    private fun lockScreenSummary() = LockScreenSummary.create(
        WatchSession.snapshot, if (simulationSession && WatchSession.simulationPaused) WatchSession.snapshot.fix?.time ?: WatchSession.now() else WatchSession.now(), WatchSession.useFeet,
        EnvironmentData.wind, EnvironmentData.point, EnvironmentData.windFetched, Instant.now())
    private fun notification(summary: LockScreenSummary): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "anchor_status_v2").setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle(if (simulationSession) "SIMULATION${if (WatchSession.simulationPaused) " · Paused" else ""} · ${WatchSession.simulationHarbor.title}" else "Nereus · Anchor watch active").setContentText(summary.compact).setContentIntent(open)
            .setStyle(Notification.BigTextStyle().bigText(summary.expanded))
            .setVisibility(Notification.VISIBILITY_PUBLIC).setShowWhen(false)
            .setSubText(summary.wind)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE).build()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
