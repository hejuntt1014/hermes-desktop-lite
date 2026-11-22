package io.github.hejuntt1014.hermes_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class MobileLoginBrowser(private val activity: Activity) {
    private data class Attempt(val url: Uri, val requestCode: Int, val reply: MethodChannel.Result)

    private var active: Attempt? = null
    private var passwordDialog: GatewayPasswordDialog? = null
    private var nextRequestCode = 22000

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "hermes_lite/login_browser").setMethodCallHandler { call, reply ->
            val url = (call.arguments as? String)?.let(Uri::parse)
            if (url == null || url.scheme !in listOf("http", "https") || url.host.isNullOrEmpty()) {
                reply.error("invalid_url", null, null)
                return@setMethodCallHandler
            }

            when (call.method) {
                "password", "open" -> open(url, reply, call.method == "password")
                "close" -> {
                    passwordDialog?.takeIf { it.start == url }?.dismiss()
                    active?.takeIf { it.url == url }?.let { attempt ->
                        active = null
                        activity.finishActivity(attempt.requestCode)
                        attempt.reply.success("closed")
                    }
                    reply.success(null)
                }
                else -> reply.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun open(url: Uri, reply: MethodChannel.Result, password: Boolean) {
        if (active != null || passwordDialog != null) {
            reply.error("login_in_progress", null, null)
            return
        }
        if (password) {
            val dialog = GatewayPasswordDialog(activity, url)
            passwordDialog = dialog
            dialog.setOnDismissListener {
                passwordDialog = null
                reply.success(dialog.callback?.toString() ?: "cancelled")
            }
            dialog.show()
            return
        }
        val intent = browserIntent(url) ?: run {
            reply.success("unavailable")
            return
        }
        val attempt = Attempt(url, nextRequestCode++, reply)
        if (nextRequestCode == 22256) nextRequestCode = 22000
        active = attempt
        try {
            activity.startActivityForResult(intent, attempt.requestCode)
        } catch (_: ActivityNotFoundException) {
            active = null
            reply.success("unavailable")
        }
    }

    @Suppress("DEPRECATION")
    private fun browserIntent(url: Uri): Intent? {
        val candidates = activity.packageManager.queryIntentServices(
            Intent(CustomTabsService.ACTION_CUSTOM_TABS_CONNECTION), 0
        ).map { it.serviceInfo.packageName }
        val provider = CustomTabsClient.getPackageName(activity, candidates) ?: return null
        val tab = CustomTabsIntent.Builder().setShowTitle(true).build()
        return tab.intent.setPackage(provider).setData(url)
    }

    fun onActivityResult(requestCode: Int): Boolean {
        val attempt = active?.takeIf { it.requestCode == requestCode } ?: return false
        active = null
        attempt.reply.success("cancelled")
        return true
    }
}
