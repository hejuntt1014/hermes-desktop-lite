package io.github.hejuntt1014.hermes_mobile

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

internal class GatewayPasswordDialog(private val owner: Activity, val start: Uri) :
    Dialog(owner, android.R.style.Theme_DeviceDefault_Light_Dialog_NoActionBar) {

    var callback: Uri? = null
        private set
    private lateinit var page: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val redirect = Uri.parse(requireNotNull(start.getQueryParameter("redirect_uri")))
        val inset = (16 * context.resources.displayMetrics.density).toInt()
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(inset, 0, inset / 2, 0)
        }
        header.addView(TextView(context).apply { text = start.encodedAuthority; textSize = 16f },
            LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        header.addView(Button(context, null, android.R.attr.borderlessButtonStyle).apply {
            setText(android.R.string.cancel)
            setOnClickListener { cancel() }
        })
        column.addView(header, MATCH_PARENT, WRAP_CONTENT)
        page = WebView(context)
        page.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
        }
        page.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val url = request.url
                if (request.isForMainFrame && url.scheme == redirect.scheme &&
                    url.encodedAuthority == redirect.encodedAuthority && url.encodedPath == redirect.encodedPath) {
                    callback = url
                    dismiss()
                    return true
                }
                return url.scheme != start.scheme || url.encodedAuthority != start.encodedAuthority
            }
        }
        column.addView(page, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        setContentView(column)
        setCanceledOnTouchOutside(false)
        window?.apply {
            setLayout(MATCH_PARENT, (owner.window.decorView.height * 0.85).toInt())
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        page.loadUrl(start.toString())
    }

    override fun dismiss() {
        super.dismiss()
        if (::page.isInitialized && page.parent != null) {
            (page.parent as? LinearLayout)?.removeView(page)
            page.destroy()
        }
    }
}
