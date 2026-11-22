package io.github.hejuntt1014.hermes_mobile

import android.app.Activity
import android.content.Intent
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private data class Export(val file: File, val reply: MethodChannel.Result)

    private var activeExport: Export? = null
    private val exportRequest = 21841
    private val alerts by lazy { MobileAlerts(this) }
    private val fileDrop by lazy { MobileFileDrop(this) }
    private val shares by lazy { MobileShares(this) }
    private val loginBrowser by lazy { MobileLoginBrowser(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        alerts.attach(flutterEngine.dartExecutor.binaryMessenger)
        MobileClipboard(this).attach(flutterEngine.dartExecutor.binaryMessenger)
        fileDrop.attach(flutterEngine.dartExecutor.binaryMessenger)
        shares.attach(flutterEngine.dartExecutor.binaryMessenger)
        loginBrowser.attach(flutterEngine.dartExecutor.binaryMessenger)
        if (shares.receive(intent)) setIntent(Intent(Intent.ACTION_MAIN))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hermes_lite/file_export")
            .setMethodCallHandler { call, reply ->
                if (call.method != "save") {
                    reply.notImplemented()
                } else {
                    val file = call.argument<String>("file")?.let(::File)
                    when {
                        file == null || !file.isFile ->
                            reply.error("file_unavailable", null, null)
                        activeExport != null ->
                            reply.error("export_in_progress", null, null)
                        else -> presentExport(file, reply)
                    }
                }
            }
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        findViewById<android.view.View>(FLUTTER_VIEW_ID)?.let(fileDrop::install)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        alerts.receive(intent)
        if (shares.receive(intent)) setIntent(Intent(Intent.ACTION_MAIN))
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        alerts.permissionResult(requestCode)
    }

    @Suppress("DEPRECATION")
    private fun presentExport(file: File, reply: MethodChannel.Result) {
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mime ?: "application/octet-stream")
            .putExtra(Intent.EXTRA_TITLE, file.name)
        activeExport = Export(file, reply)
        try {
            startActivityForResult(intent, exportRequest)
        } catch (_: Exception) {
            activeExport = null
            reply.error("picker_unavailable", null, null)
        }
    }

    @Deprecated("Called by the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (loginBrowser.onActivityResult(requestCode)) return
        if (requestCode != exportRequest) return
        val export = activeExport ?: return
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null) {
            activeExport = null
            export.reply.success(false)
            return
        }

        thread(name = "Hermes document export") {
            val written = try {
                val target = contentResolver.openOutputStream(destination, "w")
                    ?: throw IOException("Document provider returned no writable stream")
                target.use { output -> export.file.inputStream().use { it.copyTo(output) } }
                true
            } catch (_: Exception) {
                false
            }
            runOnUiThread {
                activeExport = null
                if (written) export.reply.success(true)
                else export.reply.error("file_write_failed", null, null)
            }
        }
    }
}
