package dev.phonepigeon.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import dev.phonepigeon.MainActivity
import dev.phonepigeon.R
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * Keeps the relay alive in the background (spec §8.3) with a silent,
 * minimum-importance notification that shows the connection state.
 */
class RelayForegroundService : LifecycleService() {
    companion object {
        const val CHANNEL = "relay_status"
        const val STOP = "dev.phonepigeon.STOP"
        private const val ID = 42

        fun createChannel(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Connection status", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Shows whether your Mac is connected"
                setShowBadge(false)
            })
        }
    }

    private val engine by lazy { RelayEngine.get(this) }

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
        else ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        ServiceCompat.startForeground(this, ID, notification(engine.state.value), type)
        lifecycleScope.launch {
            engine.state.map { Triple(it.connection, it.macName, it.relayed) }.distinctUntilChanged().collect {
                getSystemService(NotificationManager::class.java).notify(ID, notification(engine.state.value))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == STOP || engine.store.pairing == null) {
            engine.stop()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        engine.start()
        return START_STICKY
    }

    override fun onDestroy() {
        engine.stop()
        super.onDestroy()
    }

    private fun notification(s: EngineState): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val title = when (s.connection) {
            Connection.LAN -> "Connected to ${s.macName} via local network"
            Connection.CLOUD -> "Connected to ${s.macName} via cloud"
            Connection.CONNECTING -> "Looking for ${s.macName}…"
            Connection.OFFLINE -> "${s.macName} is offline"
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_relay)
            .setContentTitle(title)
            .setContentText("End-to-end encrypted · ${s.relayed} messages relayed")
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (RelayEngine.get(context).store.pairing != null) RelayEngine.get(context).startService()
    }
}
