package io.github.hejuntt1014.hermes_mobile

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

internal class MobileShares(private val activity: Activity) {
    private data class Share(val id: String, val text: String, val uris: List<Uri>, val readable: Boolean)

    private val queue = ArrayDeque<Share>()
    private lateinit var channel: MethodChannel
    private var copying = false

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "hermes_lite/incoming_share")
        channel.setMethodCallHandler { call, result ->
            val share = queue.firstOrNull()
            when (call.method) {
                "peek" -> result.success(share?.let {
                    mapOf("id" to it.id, "text" to it.text, "files" to it.uris.size)
                })
                "copy", "finish" -> {
                    if (share == null || share.id != call.argument<String>("id") || copying) {
                        result.error("share_unavailable", null, null)
                    } else if (call.method == "copy") {
                        copy(share, result)
                    } else {
                        val consumed = call.argument<Boolean>("consumed") == true
                        if (consumed) queue.removeFirst()
                        folder(share).deleteRecursively()
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    fun receive(intent: Intent): Boolean {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return false
        val share = runCatching {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty()
            val supplied = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            } else {
                listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            }
            val uris = supplied.ifEmpty {
                intent.clipData?.let { clip ->
                    (0 until clip.itemCount).mapNotNull { index -> clip.getItemAt(index).uri }
                }.orEmpty()
            }.distinct()
            if (text.isBlank() && uris.isEmpty()) null else Share(
                UUID.randomUUID().toString(), text, uris,
                intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
            )
        }.getOrNull()
        if (share != null) {
            queue.addLast(share)
            channel.invokeMethod("changed", null)
        }
        return true
    }

    private fun folder(share: Share) = File(activity.cacheDir, "hermes-share-${share.id}")

    private fun copy(share: Share, result: MethodChannel.Result) {
        if (share.uris.isEmpty()) {
            result.success(emptyList<String>())
            return
        }
        copying = true
        val destination = folder(share)
        thread(name = "Hermes share import") {
            val paths = try {
                val allowed = share.readable && share.uris.all { uri ->
                    uri.scheme == ContentResolver.SCHEME_CONTENT &&
                        activity.checkUriPermission(uri, Process.myPid(), Process.myUid(),
                            Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED
                }
                if (!allowed) throw SecurityException("Shared file was not granted")
                share.uris.mapIndexed { index, uri ->
                    copyGrantedAttachment(activity.contentResolver, destination, index, uri).absolutePath
                }
            } catch (_: Exception) {
                destination.deleteRecursively()
                null
            }
            activity.runOnUiThread {
                copying = false
                if (paths != null) result.success(paths)
                else result.error("share_unavailable", null, null)
            }
        }
    }
}
