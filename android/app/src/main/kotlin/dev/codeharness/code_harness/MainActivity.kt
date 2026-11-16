package dev.codeharness.code_harness

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.codeharness/bundled_runtime")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Tier 2 bundled runtime: the Dart side needs the
                    // native library dir (the only executable location
                    // since Android 10) plus the app-private dirs the
                    // engine layout (tools/bin, git-core, home, …) is
                    // built under. All setup/symlinking runs in Dart.
                    "getRuntimePaths" -> result.success(
                        mapOf(
                            "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
                            "filesDir" to filesDir.absolutePath,
                            "cacheDir" to cacheDir.absolutePath,
                        ),
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.codeharness/android_actions")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAndroidLink" -> {
                        val rawUrl = (call.arguments as? Map<*, *>)?.get("url") as? String
                        val uri = rawUrl?.let { Uri.parse(it) }
                        if (uri == null || !setOf("http", "https").contains(uri.scheme?.lowercase()) || uri.host.isNullOrBlank()) {
                            result.error("invalid_link", "Only valid http:// and https:// links can be opened.", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, uri))
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("link_open_failed", error.message ?: "No app can open this link.", null)
                            }
                        }
                    }
                    "shareAndroidText" -> {
                        val args = call.arguments as? Map<*, *>
                        val text = args?.get("text") as? String
                        val title = (args?.get("title") as? String).orEmpty().take(100)
                        if (text.isNullOrBlank() || text.length > 8000) {
                            result.error("invalid_share_text", "Shared text must contain 1–8,000 characters.", null)
                        } else {
                            try {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, text)
                                }
                                startActivity(Intent.createChooser(sendIntent, title.ifBlank { "Share text" }))
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("share_failed", error.message, null)
                            }
                        }
                    }
                    "copyAndroidText" -> {
                        val text = (call.arguments as? Map<*, *>)?.get("text") as? String
                        if (text.isNullOrBlank() || text.length > 8000) {
                            result.error("invalid_copy_text", "Copied text must contain 1–8,000 characters.", null)
                        } else {
                            try {
                                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                clipboard.setPrimaryClip(ClipData.newPlainText("Code Harness agent", text))
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("copy_failed", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // Agent foreground service (Batch 5 — desain D8): keeps the
        // agent loop alive while the app is in the background, with a
        // persistent notification naming the task.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.codeharness/agent_foreground")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = (call.arguments as? Map<*, *>)?.get("title") as? String
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .putExtra(AgentForegroundService.EXTRA_TITLE, title)
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("foreground_start_failed", error.message, null)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, AgentForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
