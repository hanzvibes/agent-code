package dev.codeharness.code_harness

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps the agent loop alive while the app is
 * in the background (Batch 5 — desain D8, keputusan Rehan 2026-11-16:
 * agent tetap jalan di background).
 *
 * Started/stopped from Dart through the `dev.codeharness/agent_foreground`
 * MethodChannel in [MainActivity]. While it runs, Android requires a
 * persistent notification naming the task; the service stops itself
 * when the task ends, and the task state is already persisted in
 * TaskStore, so even if Android kills the process under memory
 * pressure the task can be resumed from the round it stopped at.
 */
class AgentForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "agent_foreground"
        const val NOTIFICATION_ID = 1001
        const val EXTRA_TITLE = "title"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: "Agent working"
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(title))
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {
            // Already stopped: nothing to clean up.
        }
        super.onDestroy()
    }

    private fun buildNotification(title: String): Notification {
        val text = "Agent sedang mengerjakan $title"
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Code Harness agent")
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_harness)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Code Harness agent")
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_harness)
                .setOngoing(true)
                .build()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Agent",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows while the AI agent is working on a task"
        }
        manager.createNotificationChannel(channel)
    }
}
