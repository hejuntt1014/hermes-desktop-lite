package io.github.hejuntt1014.hermes_mobile

import android.app.Activity
import android.content.ContentResolver
import android.graphics.RectF
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.DragEvent
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread

internal class MobileFileDrop(private val activity: Activity) {
    private data class Target(val id: Int, val bounds: RectF)

    private lateinit var channel: MethodChannel
    private var target: Target? = null
    private var hoveredId: Int? = null
    private val reading = mutableSetOf<Int>()

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "hermes_lite/file_drop")
        channel.setMethodCallHandler { call, reply ->
            val id = call.argument<Int>("id")
            if (call.method != "target" || id == null) {
                reply.notImplemented()
                return@setMethodCallHandler
            }
            val edges = listOf("left", "top", "right", "bottom").map {
                call.argument<Number>(it)?.toFloat()
            }
            if (edges.all { it != null && it.isFinite() }) {
                if (target?.id != id) hover(null)
                target = Target(id, RectF(edges[0]!!, edges[1]!!, edges[2]!!, edges[3]!!))
            } else if (target?.id == id) {
                target = null
                hover(null)
            }
            reply.success(null)
        }
    }

    fun install(view: View) {
        view.setOnDragListener { source, drag -> onDrag(source, drag) }
    }

    private fun onDrag(view: View, drag: DragEvent): Boolean {
        return when (drag.action) {
            DragEvent.ACTION_DRAG_STARTED -> target != null && drag.localState == null
            DragEvent.ACTION_DRAG_ENTERED, DragEvent.ACTION_DRAG_LOCATION -> {
                hover(targetAt(view, drag)?.id)
                true
            }
            DragEvent.ACTION_DRAG_EXITED, DragEvent.ACTION_DRAG_ENDED -> {
                hover(null)
                true
            }
            DragEvent.ACTION_DROP -> {
                hover(null)
                val owner = targetAt(view, drag) ?: return false
                readDrop(owner.id, drag)
            }
            else -> false
        }
    }

    private fun targetAt(view: View, drag: DragEvent): Target? {
        val density = view.resources.displayMetrics.density
        return target?.takeIf {
            it.id !in reading && it.bounds.contains(drag.x / density, drag.y / density)
        }
    }

    private fun hover(id: Int?) {
        if (id == hoveredId) return
        hoveredId?.let { channel.invokeMethod("hover", mapOf("id" to it, "on" to false)) }
        hoveredId = id
        id?.let { channel.invokeMethod("hover", mapOf("id" to it, "on" to true)) }
    }

    private fun readDrop(id: Int, event: DragEvent): Boolean {
        val clip = event.clipData ?: return false
        val uris = (0 until clip.itemCount).map { index ->
            clip.getItemAt(index).uri?.takeIf { it.scheme == ContentResolver.SCHEME_CONTENT }
                ?: return false
        }.distinct()
        if (uris.isEmpty()) return false
        val permission = activity.requestDragAndDropPermissions(event)
        reading.add(id)
        channel.invokeMethod("reading", mapOf("id" to id))
        val folder = File(activity.cacheDir, "hermes-drop-${UUID.randomUUID()}")
        thread(name = "Hermes drop import") {
            val files = try {
                uris.mapIndexed { index, uri ->
                    copyGrantedAttachment(activity.contentResolver, folder, index, uri)
                }
            } catch (_: Exception) {
                null
            } finally {
                permission?.release()
            }
            activity.runOnUiThread {
                val method = if (files == null) "failed" else "files"
                channel.invokeMethod(
                    method,
                    mapOf("id" to id, "paths" to files?.map(File::getAbsolutePath)),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) = finish()
                        override fun error(code: String, message: String?, details: Any?) = finish()
                        override fun notImplemented() = finish()

                        private fun finish() {
                            reading.remove(id)
                            folder.deleteRecursively()
                        }
                    },
                )
            }
        }
        return true
    }

}

internal fun copyGrantedAttachment(resolver: ContentResolver, folder: File, index: Int, uri: Uri): File {
    if (resolver.getType(uri) == DocumentsContract.Document.MIME_TYPE_DIR) {
        throw IOException("Directories cannot be attached")
    }
    val displayName = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor -> if (cursor.moveToFirst() && cursor.columnCount != 0) cursor.getString(0) else null }
    val name = displayName?.replace('/', '_')?.replace('\\', '_')
        ?.filterNot { it.isISOControl() }?.trim()?.takeUnless { it in listOf("", ".", "..") }
        ?: "attachment-${index + 1}"
    val parent = File(folder, index.toString())
    if (!parent.mkdirs()) throw IOException("Could not open attachment cache")
    val file = File(parent, name)
    val input = resolver.openInputStream(uri) ?: throw IOException("File could not be opened")
    input.use { stream -> file.outputStream().use { stream.copyTo(it) } }
    return file
}
