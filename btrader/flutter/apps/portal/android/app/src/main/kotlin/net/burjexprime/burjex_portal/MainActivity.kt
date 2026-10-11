package net.burjexprime.burjex_portal

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // The trade-event click. A native SoundPool with several streams: every click starts at once and
    // independently. (The audio plugin's low-latency player keeps ONE stream, so in a burst of trades a click
    // either cut the previous one or never started - 10 trades vibrated 10 times but sounded about 3.)
    private var pool: SoundPool? = null
    private var eventSound = 0
    private var eventLoaded = false
    private var lastStream = 0
    private var lastClickAt = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        loadEventSound()
        // Trade feedback: SoundService vibrates through the real Vibrator service and plays the event click here
        // (lib/services/sound_service.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "burjex/haptics").setMethodCallHandler { call, result ->
            when (call.method) {
                "click" -> result.success(playEventClick())
                "vibrate" -> {
                    val pattern = (call.argument<List<Number>>("pattern") ?: emptyList()).map { it.toLong() }.toLongArray()
                    try {
                        val v = vibrator()
                        if (v == null || !v.hasVibrator() || pattern.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            v.vibrate(VibrationEffect.createWaveform(pattern, -1))
                        } else {
                            @Suppress("DEPRECATION")
                            v.vibrate(pattern, -1)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("vibrate", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun loadEventSound() {
        try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val p = SoundPool.Builder().setMaxStreams(8).setAudioAttributes(attrs).build()
            p.setOnLoadCompleteListener { _, id, status -> if (status == 0 && id == eventSound) eventLoaded = true }
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset("assets/sounds/order_event.wav")
            assets.openFd(key).use { eventSound = p.load(it, 1) }
            pool = p
        } catch (e: Exception) {
            pool = null // the Dart side falls back to the audio plugin
        }
    }

    /** Plays the click now; false when the native sound is not ready (Dart then uses its fallback). */
    private fun playEventClick(): Boolean {
        val p = pool ?: return false
        if (!eventLoaded) return false
        return try {
            // In a fast burst the previous click is cut as the next starts, so a series stays a series of clicks
            // instead of one smear; a lone event always plays in full.
            val now = System.currentTimeMillis()
            if (lastStream != 0 && now - lastClickAt < 300) p.stop(lastStream)
            lastStream = p.play(eventSound, 1f, 1f, 1, 0, 1f)
            lastClickAt = now
            lastStream != 0
        } catch (e: Exception) {
            false
        }
    }

    override fun onDestroy() {
        pool?.release()
        pool = null
        super.onDestroy()
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
}
