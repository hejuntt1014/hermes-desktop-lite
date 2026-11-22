package io.github.hejuntt1014.hermes_mobile

import android.app.Activity
import android.content.ClipboardManager
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread

internal class MobileClipboard(private val activity: Activity) {
    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "hermes_lite/image_clipboard").setMethodCallHandler { call, reply ->
            if (call.method != "readImages") {
                reply.notImplemented()
                return@setMethodCallHandler
            }
            val directory = call.argument<String>("directory")?.let(::File)
            val limit = call.argument<Int>("limit")
            if (directory == null || limit == null || limit !in 0..10) {
                reply.error("clipboard_unavailable", null, null)
                return@setMethodCallHandler
            }
            val clip = try {
                activity.getSystemService(ClipboardManager::class.java)?.primaryClip
            } catch (_: SecurityException) {
                reply.error("clipboard_unavailable", null, null)
                return@setMethodCallHandler
            }
            if (clip == null) {
                reply.success(emptyList<String>())
                return@setMethodCallHandler
            }
            val advertisedImage = clip.description.hasMimeType("image/*")
            val uris = (0 until clip.itemCount).mapNotNull { index ->
                clip.getItemAt(index).uri?.takeIf { it.scheme == "content" }
            }
            if (uris.isEmpty() && !advertisedImage) {
                reply.success(emptyList<String>())
                return@setMethodCallHandler
            }
            thread(name = "Hermes clipboard import") {
                try {
                    val names = stageImages(directory, uris, advertisedImage, limit)
                    activity.runOnUiThread { reply.success(names) }
                } catch (_: TooManyImages) {
                    activity.runOnUiThread { reply.error("too_many_images", null, null) }
                } catch (_: Exception) {
                    activity.runOnUiThread { reply.error("clipboard_unavailable", null, null) }
                }
            }
        }
    }

    private fun stageImages(
        directory: File,
        uris: List<Uri>,
        advertisedImage: Boolean,
        limit: Int
    ): List<String> {
        val target = directory.canonicalFile
        if (target.parentFile != activity.cacheDir.canonicalFile ||
            !target.name.startsWith("hermes-clipboard-") || !target.isDirectory) {
            throw IOException("Invalid clipboard staging directory")
        }
        val resolver = activity.contentResolver
        val images = uris.distinct().mapNotNull { uri ->
            val type = resolver.getType(uri)
            when {
                type?.startsWith("image/") == true -> ImageSource(uri, null)
                !advertisedImage -> null
                else -> {
                    val streamType = resolver.getStreamTypes(uri, "image/*")
                        ?.firstOrNull { it.startsWith("image/") }
                    when {
                        streamType != null -> ImageSource(uri, streamType)
                        advertisedImage && type == null -> ImageSource(uri, null)
                        else -> null
                    }
                }
            }
        }
        if (images.size > limit) throw TooManyImages()
        if (images.isEmpty() && advertisedImage) throw IOException("No readable clipboard image")
        return images.mapIndexed { index, image ->
            val name = "clipboard-${index + 1}"
            val file = File(target, name)
            if (image.streamType == null) {
                val input = resolver.openInputStream(image.uri)
                    ?: throw IOException("Cannot open clipboard image")
                input.use { source -> file.outputStream().use { source.copyTo(it) } }
            } else {
                val asset = resolver.openTypedAssetFileDescriptor(image.uri, image.streamType, null)
                    ?: throw IOException("Cannot open clipboard image")
                asset.use {
                    it.createInputStream().use { source ->
                        file.outputStream().use { source.copyTo(it) }
                    }
                }
            }
            if (file.length() == 0L) throw IOException("Empty clipboard image")
            name
        }
    }

    private data class ImageSource(val uri: Uri, val streamType: String?)
    private class TooManyImages : Exception()
}
