package dev.phonepigeon.screen

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.phonepigeon.R
import dev.phonepigeon.proto.ScreenMirrorStatus
import dev.phonepigeon.proto.ScreenState
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.LinkedBlockingQueue
import kotlin.math.max
import kotlin.math.min

/**
 * Screen mirroring (view only). The phone captures its screen with MediaProjection, encodes H.264 on the GPU
 * encoder and serves the frames to the paired Mac over the same pinned-TLS, token-authenticated media server
 * as photos and files (`GET /media/screen`). It never leaves the local network and never touches the relay.
 *
 * Safety: every session needs the phone's owner to tap the request notification and accept Android's own
 * screen-capture dialog; a persistent notification with a Stop button is shown while streaming; windows that set
 * FLAG_SECURE (banking apps, password fields) are blanked by Android itself.
 */
object ScreenMirror {
    /** kind: 1 = codec config (SPS+PPS, Annex B), 2 = key frame, 3 = delta frame. */
    class Frame(val kind: Byte, val ptsUs: Long, val data: ByteArray)

    class Subscriber {
        val queue = LinkedBlockingQueue<Frame>(12)
        @Volatile var closed = false
        @Volatile var needKey = true
        fun close() { closed = true; queue.offer(Frame(0, 0, ByteArray(0))) }
    }

    private val subscribers = CopyOnWriteArrayList<Subscriber>()
    @Volatile private var config: ByteArray? = null
    @Volatile var active = false
        private set
    @Volatile var lastStatus = ScreenMirrorStatus(ScreenState.SCREEN_IDLE)
        private set

    /** Wired by the relay engine: statuses go to the Mac over the encrypted control channel. */
    @Volatile var statusSink: ((ScreenMirrorStatus) -> Unit)? = null
    internal var requestKeyFrame: (() -> Unit)? = null
    /** Set by the running service so a stop request doesn't depend on a (possibly slow) binder call to the system. */
    internal var stopHandler: (() -> Unit)? = null

    /** Set by the engine: whether the Mac may also send touch/keyboard input right now. */
    @Volatile var controlAvailable: () -> Boolean = { false }

    fun report(state: ScreenState, width: Int = 0, height: Int = 0, message: String = "", control: Boolean = false) {
        val s = ScreenMirrorStatus(state, width, height, message, control)
        lastStatus = s
        statusSink?.invoke(s)
    }

    fun subscribe(): Subscriber {
        val s = Subscriber()
        subscribers += s
        requestKeyFrame?.invoke()
        return s
    }

    fun unsubscribe(s: Subscriber) { subscribers -= s }

    fun currentConfig(): ByteArray? = config

    internal fun publishConfig(bytes: ByteArray) {
        config = bytes
        subscribers.forEach { s -> s.needKey = true; s.queue.offer(Frame(1, 0, bytes)) }
    }

    internal fun publish(frame: Frame) {
        for (s in subscribers) {
            if (s.closed) continue
            if (s.needKey && frame.kind != 2.toByte()) continue
            if (frame.kind == 2.toByte()) s.needKey = false
            if (!s.queue.offer(frame)) {
                // The Mac is behind: drop everything queued and resume at the next key frame (keeps latency low).
                s.queue.clear(); s.needKey = true; requestKeyFrame?.invoke()
            }
        }
    }

    internal fun streamEnded() {
        active = false
        config = null
        subscribers.forEach { it.close() }
        subscribers.clear()
    }

    internal fun markActive() { active = true }

    fun stop(context: Context) {
        stopHandler?.let { it(); return }
        context.startService(Intent(context, ScreenMirrorService::class.java).setAction(ScreenMirrorService.ACTION_STOP))
    }

    // ------------------------------------------------------------------ consent request

    private const val REQUEST_CHANNEL = "screen_request"
    private const val REQUEST_ID = 77

    /** Asks the phone's owner (via a notification they must tap) before anything is captured. */
    fun requestFromMac(context: Context, macName: String, maxDimension: Int) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(REQUEST_CHANNEL, "Screen mirroring requests", NotificationManager.IMPORTANCE_HIGH))
        val intent = Intent(context, ScreenMirrorConsentActivity::class.java)
            .putExtra(ScreenMirrorService.EXTRA_MAX, maxDimension)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val tap = PendingIntent.getActivity(context, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        nm.notify(REQUEST_ID, NotificationCompat.Builder(context, REQUEST_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle("$macName wants to show your screen")
            .setContentText("Tap to review. Nothing is shared until you allow it.")
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setTimeoutAfter(2 * 60_000)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build())
        // If PhonePigeon is already on screen the dialog can open straight away.
        runCatching { context.startActivity(intent) }
    }

    fun cancelRequest(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(REQUEST_ID)
    }
}

/** Translucent activity that shows Android's own capture-consent dialog. */
class ScreenMirrorConsentActivity : ComponentActivity() {
    private val launcher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        ScreenMirror.cancelRequest(this)
        if (r.resultCode == Activity.RESULT_OK && r.data != null) {
            ContextCompat.startForegroundService(this, Intent(this, ScreenMirrorService::class.java)
                .putExtra(ScreenMirrorService.EXTRA_CODE, r.resultCode)
                .putExtra(ScreenMirrorService.EXTRA_DATA, r.data)
                .putExtra(ScreenMirrorService.EXTRA_MAX, intent.getIntExtra(ScreenMirrorService.EXTRA_MAX, 1280)))
        } else {
            ScreenMirror.report(ScreenState.SCREEN_DENIED, message = "Screen sharing was declined on the phone.")
        }
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            val mgr = getSystemService(MediaProjectionManager::class.java)
            // Android 14+: offer only "entire screen" (no single-app picker): mirroring one app goes blank as soon as
            // you leave it, which looks like the mirror ending.
            val intent = if (Build.VERSION.SDK_INT >= 34)
                mgr.createScreenCaptureIntent(android.media.projection.MediaProjectionConfig.createConfigForDefaultDisplay())
            else mgr.createScreenCaptureIntent()
            launcher.launch(intent)
        }
    }
}

/** Foreground service that owns the MediaProjection, the virtual display and the H.264 encoder. */
class ScreenMirrorService : Service() {
    companion object {
        const val ACTION_STOP = "dev.phonepigeon.SCREEN_STOP"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        const val EXTRA_MAX = "max"
        private const val CHANNEL = "screen_mirroring"
        private const val ID = 78
        private const val TAG = "PhonePigeon"
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    @Volatile private var running = false
    private var worker: Thread? = null
    private var maxDimension = 1280
    private var lastOrientation = Configuration.ORIENTATION_UNDEFINED
    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { shutdown("Stopped"); return START_NOT_STICKY }
        val code = intent?.getIntExtra(EXTRA_CODE, 0) ?: 0
        val data = intent?.let { if (Build.VERSION.SDK_INT >= 33) it.getParcelableExtra(EXTRA_DATA, Intent::class.java) else @Suppress("DEPRECATION") it.getParcelableExtra(EXTRA_DATA) }
        if (data == null) { shutdown("No capture permission", ScreenState.SCREEN_ERROR); return START_NOT_STICKY }
        maxDimension = (intent.getIntExtra(EXTRA_MAX, 1280)).coerceIn(480, 1920)

        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Screen mirroring", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0, Intent(this, ScreenMirrorService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val note: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle("Your screen is being shown on your Mac")
            .setContentText("Tap Stop to end screen mirroring.")
            .addAction(0, "Stop", stop)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        ServiceCompat.startForeground(this, ID, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)

        return runCatching {
            val mgr = getSystemService(MediaProjectionManager::class.java)
            projection = mgr.getMediaProjection(code, data)?.also { p ->
                // Android 14+: the callback must be registered before a virtual display is created.
                p.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() { main.post { shutdown("Stopped from the phone") } }
                }, main)
            }
            lastOrientation = resources.configuration.orientation
            startPipeline()
            START_NOT_STICKY
        }.getOrElse {
            Log.w(TAG, "screen mirroring failed: ${it.message}")
            shutdown(it.message ?: "Couldn't start screen capture", ScreenState.SCREEN_ERROR)
            START_NOT_STICKY
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (running && newConfig.orientation != lastOrientation) {
            lastOrientation = newConfig.orientation
            stopPipeline()
            runCatching { startPipeline() }.onFailure { shutdown(it.message ?: "Couldn't resize", ScreenState.SCREEN_ERROR) }
        }
    }

    private fun startPipeline() {
        val bounds = getSystemService(WindowManager::class.java).currentWindowMetrics.bounds
        val scale = min(1f, maxDimension.toFloat() / max(bounds.width(), bounds.height()))
        var w = (bounds.width() * scale).toInt()
        var h = (bounds.height() * scale).toInt()

        // Encoders differ a lot between vendors (tablets especially): honour the codec's size alignment, and fall back
        // through simpler settings and smaller sizes instead of failing outright.
        var lastError: Exception? = null
        for (attempt in 0 until 4) {
            val (aw, ah) = align(w, h)
            for (profile in intArrayOf(MediaCodecInfo.CodecProfileLevel.AVCProfileHigh, MediaCodecInfo.CodecProfileLevel.AVCProfileMain, 0)) {
                try {
                    startEncoder(aw, ah, profile)
                    return
                } catch (e: Exception) {
                    lastError = e
                    Log.w(TAG, "encoder ${aw}x$ah profile $profile failed: ${e.javaClass.simpleName} ${e.message}")
                    stopPipeline()
                }
            }
            w = (w * 0.75f).toInt(); h = (h * 0.75f).toInt() // smaller picture, easier for weak encoders
        }
        throw IllegalStateException("This device's video encoder couldn't start (${lastError?.javaClass?.simpleName}: ${lastError?.message})")
    }

    private fun align(w: Int, h: Int): Pair<Int, Int> {
        val caps = runCatching {
            val list = android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS)
            list.codecInfos.firstOrNull { it.isEncoder && it.supportedTypes.any { t -> t.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } }
                ?.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)?.videoCapabilities
        }.getOrNull()
        val wa = max(2, caps?.widthAlignment ?: 2).coerceAtLeast(16)
        val ha = max(2, caps?.heightAlignment ?: 2).coerceAtLeast(16)
        var aw = (w / wa * wa).coerceAtLeast(wa)
        var ah = (h / ha * ha).coerceAtLeast(ha)
        caps?.let {
            aw = aw.coerceIn(it.supportedWidths.lower, it.supportedWidths.upper)
            ah = ah.coerceIn(it.supportedHeights.lower, it.supportedHeights.upper)
        }
        return aw to ah
    }

    private fun startEncoder(w: Int, h: Int, profile: Int) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, (w * h * 30 * 0.07).toInt().coerceIn(1_500_000, 8_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            if (profile != 0) setInteger(MediaFormat.KEY_PROFILE, profile)
            runCatching { setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 500_000) } // static screens still produce frames
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        } catch (e: Exception) { runCatching { enc.release() }; throw e }
        val surface = enc.createInputSurface()
        enc.start()
        encoder = enc
        display = projection!!.createVirtualDisplay("phonepigeon-mirror", w, h, resources.configuration.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)

        running = true
        ScreenMirror.markActive()
        ScreenMirror.requestKeyFrame = {
            runCatching { encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
        }
        ScreenMirror.stopHandler = { main.post { shutdown("Stopped from your Mac") } }
        worker = Thread({ drain(enc) }, "phonepigeon-screen-encoder").also { it.start() }
        ScreenMirror.report(ScreenState.SCREEN_STREAMING, w, h, control = ScreenMirror.controlAvailable())
    }

    private fun drain(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running && encoder === enc) {
                val i = enc.dequeueOutputBuffer(info, 100_000)
                if (i < 0) continue
                val buf = enc.getOutputBuffer(i)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size).also { buf.get(it) }
                    when {
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 -> ScreenMirror.publishConfig(bytes)
                        else -> ScreenMirror.publish(ScreenMirror.Frame(
                            if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) 2 else 3, info.presentationTimeUs, bytes))
                    }
                }
                enc.releaseOutputBuffer(i, false)
            }
        } catch (e: Exception) {
            if (running) Log.w(TAG, "encoder stopped: ${e.message}")
        }
    }

    private fun stopPipeline() {
        running = false
        runCatching { worker?.join(500) }
        runCatching { display?.release() }
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        display = null; encoder = null; worker = null
    }

    private fun shutdown(message: String, state: ScreenState = ScreenState.SCREEN_STOPPED) {
        val wasActive = ScreenMirror.active
        stopPipeline()
        runCatching { projection?.stop() }
        projection = null
        ScreenMirror.requestKeyFrame = null
        ScreenMirror.stopHandler = null
        ScreenMirror.streamEnded()
        ScreenMirror.report(state, message = message)
        if (!wasActive && state == ScreenState.SCREEN_STOPPED) Log.i(TAG, "screen mirroring never started")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (running || projection != null) {
            stopPipeline(); runCatching { projection?.stop() }; projection = null
            ScreenMirror.streamEnded()
        }
        super.onDestroy()
    }
}
