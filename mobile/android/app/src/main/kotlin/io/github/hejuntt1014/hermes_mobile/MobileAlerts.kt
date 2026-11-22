package io.github.hejuntt1014.hermes_mobile

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

internal class MobileAlerts(private val activity: MainActivity) {
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private val targets = activity.getSharedPreferences("notification_open", 0)
    private val openAction = activity.packageName + ".OPEN_NOTIFICATION"
    private val channelId = "hermes_chat"
    private val permissionRequest = 21842
    private var permissionReply: MethodChannel.Result? = null
    private var opened: String? = null
    private lateinit var channel: MethodChannel

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "hermes_lite/notifications")
        channel.setMethodCallHandler { call, reply ->
            when (call.method) {
                "status" -> reply.success(enabled())
                "request" -> requestPermission(reply)
                "settings" -> {
                    val settings = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    } else {
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + activity.packageName))
                    }
                    activity.startActivity(settings)
                    reply.success(null)
                }
                "post" -> post(call, reply)
                "remove" -> {
                    val id = call.arguments as? String
                    if (id != null) {
                        manager.cancel(id, 0)
                        targets.edit().remove(id).apply()
                    }
                    reply.success(null)
                }
                "takeOpened" -> {
                    consume(activity.intent)
                    reply.success(opened)
                    opened = null
                }
                else -> reply.notImplemented()
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    activity.getString(R.string.conversation_notifications),
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
        }
    }

    private fun enabled(): Boolean {
        val permitted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val enabledInSettings = Build.VERSION.SDK_INT < Build.VERSION_CODES.N || manager.areNotificationsEnabled()
        return permitted && enabledInSettings &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                manager.getNotificationChannel(channelId)?.importance != NotificationManager.IMPORTANCE_NONE)
    }

    private fun requestPermission(reply: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            reply.success(enabled())
        } else if (permissionReply != null) {
            reply.success(false)
        } else {
            permissionReply = reply
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), permissionRequest)
        }
    }

    fun permissionResult(requestCode: Int) {
        if (requestCode != permissionRequest) return
        permissionReply?.success(enabled())
        permissionReply = null
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun post(call: MethodCall, reply: MethodChannel.Result) {
        val id = call.argument<String>("id")
        val title = call.argument<String>("title")
        val body = call.argument<String>("body")
        val route = call.argument<String>("route")
        if (id == null || title == null || body == null || !enabled()) {
            reply.success(false)
            return
        }
        val token = UUID.randomUUID().toString()
        val intent = Intent(activity, MainActivity::class.java)
            .setAction(openAction)
            .setPackage(activity.packageName)
            .setData(Uri.Builder().scheme("hermes-alert").authority("tap").appendPath(token).build())
            .putExtra("notification_id", id)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(
            activity, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
        )
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(activity, channelId).setTimeoutAfter(60 * 60 * 1000L)
        } else {
            Notification.Builder(activity)
        }
        val editor = targets.edit()
        val retained = targets.all.entries.filter { it.key != id }
            .sortedByDescending { decode(it.value as? String)?.optLong("time") ?: 0L }
        retained.drop(63).forEach {
            manager.cancel(it.key, 0)
            editor.remove(it.key)
        }
        editor.putString(
            id, JSONObject().put("token", token).put("route", route)
                .put("time", System.currentTimeMillis()).toString()
        ).apply()
        try {
            manager.notify(id, 0, notification
                .setSmallIcon(android.R.drawable.ic_dialog_email)
                .setContentTitle(title)
                .setContentText(body)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build())
            reply.success(true)
        } catch (_: SecurityException) {
            targets.edit().remove(id).apply()
            reply.success(false)
        }
    }

    fun receive(intent: Intent) {
        if (consume(intent) && ::channel.isInitialized) channel.invokeMethod("opened", null)
    }

    private fun consume(intent: Intent?): Boolean {
        if (intent?.action != openAction) return false
        val id = intent.getStringExtra("notification_id") ?: return false
        val token = intent.data?.lastPathSegment ?: return false
        val saved = decode(targets.getString(id, null)) ?: return false
        if (saved.optString("token") != token) return false
        targets.edit().remove(id).apply()
        val age = System.currentTimeMillis() - saved.optLong("time")
        if (age !in 0..(60 * 60 * 1000L) || !saved.has("route")) return false
        opened = saved.optString("route")
        return true
    }

    private fun decode(raw: String?): JSONObject? = if (raw == null) null else
        runCatching { JSONObject(raw) }.getOrNull()
}
