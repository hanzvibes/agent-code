package dev.codeharness.code_harness

import android.content.BroadcastReceiver
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

private const val TERMUX_PACKAGE = "com.termux"
private const val TERMUX_RUN_COMMAND_ACTION = "com.termux.RUN_COMMAND"
private const val TERMUX_RUN_COMMAND_SERVICE = "com.termux.app.RunCommandService"
private const val TERMUX_PERMISSION_RUN_COMMAND = "com.termux.permission.RUN_COMMAND"
private const val EXTRA_REQUEST_ID = "dev.codeharness.termux.REQUEST_ID"
private const val RESULT_BUNDLE = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE"
private const val RESULT_STDOUT = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE_STDOUT"
private const val RESULT_STDERR = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE_STDERR"
private const val RESULT_EXIT_CODE = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE_EXIT_CODE"
private const val RESULT_ERR = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE_ERR"
private const val RESULT_ERRMSG = "com.termux.service.EXTRA_PLUGIN_RESULT_BUNDLE_ERRMSG"
private const val MAX_OUTPUT_CHARS_PER_STREAM = 16000

private data class ActiveTermuxCommand(
    val requestId: String,
    val server: ServerSocket,
    val token: String,
    val cancelRequested: AtomicBoolean = AtomicBoolean(false),
    val controlSocket: AtomicReference<Socket?> = AtomicReference(null),
    @Volatile var localExitCode: Int? = null,
    @Volatile var stdoutChars: Int = 0,
    @Volatile var stderrChars: Int = 0,
    @Volatile var stdoutTruncated: Boolean = false,
    @Volatile var stderrTruncated: Boolean = false,
    @Volatile var stdoutConnected: Boolean = false,
    @Volatile var stderrConnected: Boolean = false,
    val streamsDone: CountDownLatch = CountDownLatch(3),
)

private object TermuxBridgeEvents {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val queuedEvents = ArrayDeque<Map<String, Any?>>()
    private var sink: EventChannel.EventSink? = null
    val activeCommands = ConcurrentHashMap<String, ActiveTermuxCommand>()

    @Synchronized
    fun setSink(eventSink: EventChannel.EventSink?) {
        sink = eventSink
        if (eventSink != null) {
            while (queuedEvents.isNotEmpty()) eventSink.success(queuedEvents.removeFirst())
        }
    }

    fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            synchronized(this) {
                val current = sink
                if (current != null) {
                    current.success(event)
                } else {
                    if (queuedEvents.size >= 256) queuedEvents.removeFirst()
                    queuedEvents.addLast(event)
                }
            }
        }
    }

    fun cancel(requestId: String) {
        val active = activeCommands[requestId] ?: return
        active.cancelRequested.set(true)
        try {
            active.controlSocket.get()?.getOutputStream()?.apply {
                write("CANCEL\n".toByteArray(StandardCharsets.UTF_8))
                flush()
            }
        } catch (_: Exception) {
            // If the control socket is not connected yet, the relay sends the
            // cancellation as soon as it accepts that socket.
        }
    }

    fun finish(requestId: String) {
        val active = activeCommands.remove(requestId) ?: return
        try { active.controlSocket.get()?.close() } catch (_: Exception) {}
        try { active.server.close() } catch (_: Exception) {}
    }
}

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.codeharness/termux")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTermuxStatus" -> result.success(
                        mapOf(
                            "installed" to isTermuxInstalled(),
                            "permissionGranted" to (checkSelfPermission(TERMUX_PERMISSION_RUN_COMMAND) == PackageManager.PERMISSION_GRANTED),
                        ),
                    )
                    "openTermux" -> openTermux(result)
                    "openAppPermissionSettings" -> openAppPermissionSettings(result)
                    "startTermuxCommand" -> startTermuxCommand(call.arguments as? Map<*, *>, result)
                    "cancelTermuxCommand" -> {
                        val requestId = (call.arguments as? Map<*, *>)?.get("requestId") as? String
                        if (requestId.isNullOrBlank()) {
                            result.error("invalid_request", "Missing command request id.", null)
                        } else {
                            TermuxBridgeEvents.cancel(requestId)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
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
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.codeharness/termux_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    TermuxBridgeEvents.setSink(events)
                }
                override fun onCancel(arguments: Any?) {
                    TermuxBridgeEvents.setSink(null)
                }
            })
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

    private fun isTermuxInstalled(): Boolean = try {
        if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getPackageInfo(TERMUX_PACKAGE, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(TERMUX_PACKAGE, 0)
        }
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private fun openTermux(result: MethodChannel.Result) {
        if (!isTermuxInstalled()) {
            result.error("termux_not_installed", "Install and open Termux before enabling the runtime.", null)
            return
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(TERMUX_PACKAGE)
        if (launchIntent == null) {
            result.error("termux_not_launchable", "Could not open the Termux app.", null)
            return
        }
        try {
            startActivity(launchIntent)
            result.success(null)
        } catch (error: Exception) {
            result.error("termux_open_failed", error.message, null)
        }
    }

    private fun openAppPermissionSettings(result: MethodChannel.Result) {
        try {
            startActivity(
                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
            result.success(null)
        } catch (error: Exception) {
            result.error("settings_open_failed", error.message, null)
        }
    }

    private fun startTermuxCommand(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val command = arguments?.get("command") as? String
        val workspaceRoot = arguments?.get("workspaceRoot") as? String
        val workingDirectory = arguments?.get("workingDirectory") as? String
        val timeoutSeconds = (arguments?.get("timeoutSeconds") as? Number)?.toInt()
        if (command.isNullOrBlank() || workspaceRoot.isNullOrBlank() || workingDirectory.isNullOrBlank() || timeoutSeconds == null) {
            result.error("invalid_command", "Missing command, workspace path, working directory, or timeout.", null)
            return
        }
        if (!isTermuxInstalled()) {
            result.error("termux_not_installed", "Termux is not installed. Install and set it up, then retry.", null)
            return
        }
        if (checkSelfPermission(TERMUX_PERMISSION_RUN_COMMAND) != PackageManager.PERMISSION_GRANTED) {
            result.error(
                "termux_permission_missing",
                "Grant this app the 'Run commands in Termux environment' permission in Android app settings.",
                null,
            )
            return
        }
        if (!isSharedStoragePath(workspaceRoot)) {
            result.error(
                "workspace_not_shared",
                "Termux can access only shared-storage workspaces in this adapter. Move or reopen the project under /storage/emulated/0 and run termux-setup-storage in Termux.",
                null,
            )
            return
        }
        if (command.length > 32000) {
            result.error("command_too_long", "Command exceeds the 32,000 character limit.", null)
            return
        }

        val boundedTimeout = timeoutSeconds.coerceIn(1, 120)
        val requestId = UUID.randomUUID().toString()
        val token = UUID.randomUUID().toString().replace("-", "")
        val server = try {
            ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")).apply {
                soTimeout = (boundedTimeout + 20) * 1000
            }
        } catch (error: Exception) {
            result.error("termux_relay_failed", "Could not start local output relay: ${error.message}", null)
            return
        }
        val active = ActiveTermuxCommand(requestId, server, token)
        TermuxBridgeEvents.activeCommands[requestId] = active
        Thread({ acceptRelayConnections(active) }, "termux-relay-$requestId").start()

        try {
            val termuxIntent = Intent().apply {
                setClassName(TERMUX_PACKAGE, TERMUX_RUN_COMMAND_SERVICE)
                action = TERMUX_RUN_COMMAND_ACTION
                putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-lc", buildRelayScript(server.localPort, token, boundedTimeout)))
                putExtra("com.termux.RUN_COMMAND_STDIN", command)
                putExtra("com.termux.RUN_COMMAND_WORKDIR", workingDirectory)
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
                putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
                putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "Code Harness agent command")
                putExtra(
                    "com.termux.RUN_COMMAND_COMMAND_DESCRIPTION",
                    "Runs an AI-requested shell command on this device in the selected project directory. Commands may change files and use the network.",
                )
                putExtra(
                    "com.termux.RUN_COMMAND_COMMAND_HELP",
                    "Code Harness streams command output and returns the exit status. The command runs with Termux permissions, not inside a sandbox.",
                )
                val callback = Intent(this@MainActivity, TermuxCommandResultReceiver::class.java).apply {
                    putExtra(EXTRA_REQUEST_ID, requestId)
                }
                val flags = PendingIntent.FLAG_ONE_SHOT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                val callbackPendingIntent = PendingIntent.getBroadcast(
                    this@MainActivity,
                    requestId.hashCode(),
                    callback,
                    flags,
                )
                putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callbackPendingIntent)
            }
            startService(termuxIntent)
            result.success(requestId)
        } catch (error: SecurityException) {
            TermuxBridgeEvents.finish(requestId)
            result.error("termux_permission_missing", "Termux denied the command. Check its allow-external-apps setting and the Android Run commands permission. ${error.message}", null)
        } catch (error: Exception) {
            TermuxBridgeEvents.finish(requestId)
            result.error("termux_start_failed", "Could not start the Termux command service: ${error.message}", null)
        }
    }

    private fun acceptRelayConnections(active: ActiveTermuxCommand) {
        try {
            repeat(3) {
                val socket = active.server.accept()
                socket.soTimeout = 10000
                val hello = readAsciiLine(socket, 256)
                val prefix = "${active.token}|"
                if (!hello.startsWith(prefix)) {
                    socket.close()
                    return@repeat
                }
                val channel = hello.removePrefix(prefix)
                socket.soTimeout = 0
                when (channel) {
                    "control" -> {
                        active.controlSocket.set(socket)
                        if (active.cancelRequested.get()) {
                            socket.getOutputStream().apply {
                                write("CANCEL\n".toByteArray(StandardCharsets.UTF_8))
                                flush()
                            }
                        }
                        Thread({ readControlResults(active, socket) }, "termux-control-${active.requestId}").start()
                    }
                    "stdout", "stderr" -> {
                        if (channel == "stdout") active.stdoutConnected = true else active.stderrConnected = true
                        Thread(
                            { relayOutput(active, channel, socket) },
                            "termux-$channel-${active.requestId}",
                        ).start()
                    }
                    else -> socket.close()
                }
            }
        } catch (error: Exception) {
            if (!active.server.isClosed) {
                TermuxBridgeEvents.emit(
                    mapOf("type" to "relayError", "requestId" to active.requestId, "message" to (error.message ?: "Local output relay failed.")),
                )
            }
        }
    }

    private fun readAsciiLine(socket: Socket, maxBytes: Int): String {
        val bytes = ByteArrayOutputStream()
        while (bytes.size() < maxBytes) {
            val next = socket.getInputStream().read()
            if (next == -1 || next == '\n'.code) break
            if (next != '\r'.code) bytes.write(next)
        }
        return bytes.toString("UTF-8")
    }

    private fun relayOutput(active: ActiveTermuxCommand, channel: String, socket: Socket) {
        try {
            val reader = InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8)
            val buffer = CharArray(2048)
            while (true) {
                val count = reader.read(buffer)
                if (count < 0) break
                if (count > 0) {
                    val already = if (channel == "stderr") active.stderrChars else active.stdoutChars
                    val remaining = (MAX_OUTPUT_CHARS_PER_STREAM - already).coerceAtLeast(0)
                    val accepted = count.coerceAtMost(remaining)
                    if (accepted > 0) {
                        TermuxBridgeEvents.emit(
                            mapOf("type" to "output", "requestId" to active.requestId, "channel" to channel, "chunk" to String(buffer, 0, accepted)),
                        )
                        if (channel == "stderr") active.stderrChars += accepted else active.stdoutChars += accepted
                    }
                    if (accepted < count) {
                        if (channel == "stderr") active.stderrTruncated = true else active.stdoutTruncated = true
                    }
                }
            }
        } catch (_: Exception) {
            // Closing a stream during cancellation is expected.
        } finally {
            try { socket.close() } catch (_: Exception) {}
            active.streamsDone.countDown()
        }
    }

    private fun readControlResults(active: ActiveTermuxCommand, socket: Socket) {
        try {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8))
            while (true) {
                val line = reader.readLine() ?: break
                val exitCode = line.trim().toIntOrNull()
                if (exitCode != null) active.localExitCode = exitCode
            }
        } catch (_: Exception) {
            // Termux's final PendingIntent also reports the execution status.
        } finally {
            try { socket.close() } catch (_: Exception) {}
            active.streamsDone.countDown()
        }
    }

    private fun buildRelayScript(port: Int, token: String, timeoutSeconds: Int): String = """
        set +e
        exec 3<>/dev/tcp/127.0.0.1/$port || exit 125
        printf '%s\n' '$token|control' >&3
        exec 4<>/dev/tcp/127.0.0.1/$port || exit 125
        printf '%s\n' '$token|stdout' >&4
        exec 5<>/dev/tcp/127.0.0.1/$port || exit 125
        printf '%s\n' '$token|stderr' >&5
        if ! command -v timeout >/dev/null 2>&1; then
          printf '%s\n' 'Termux coreutils is required for bounded command timeouts. Run: pkg install coreutils' >&5
          printf '%s\n' '127' >&3
          exit 127
        fi
        timeout --signal=TERM --kill-after=2s ${timeoutSeconds}s /data/data/com.termux/files/usr/bin/bash -c "${'$'}(cat)" >&4 2>&5 &
        command_pid=${'$'}!
        while kill -0 ${'$'}command_pid 2>/dev/null; do
          if IFS= read -r -t 0.25 control_message <&3; then
            if [ "${'$'}control_message" = 'CANCEL' ]; then kill -TERM ${'$'}command_pid 2>/dev/null; fi
          fi
        done
        wait ${'$'}command_pid
        command_exit=${'$'}?
        printf '%s\n' "${'$'}command_exit" >&3
        exit ${'$'}command_exit
    """.trimIndent()

    private fun isSharedStoragePath(path: String): Boolean {
        val normalized = path.replace('\\', '/')
        return normalized == "/sdcard" || normalized.startsWith("/sdcard/") ||
            normalized == "/storage/emulated/0" || normalized.startsWith("/storage/emulated/0/") ||
            normalized == "/storage/self/primary" || normalized.startsWith("/storage/self/primary/") ||
            Regex("^/storage/[0-9A-Fa-f-]{8,}/").containsMatchIn(normalized)
    }
}

class TermuxCommandResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pendingResult = goAsync()
        Thread({
            try {
                processResult(intent)
            } finally {
                pendingResult.finish()
            }
        }, "termux-result").start()
    }

    private fun processResult(intent: Intent) {
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
        val active = TermuxBridgeEvents.activeCommands[requestId]
        active?.streamsDone?.await(2, TimeUnit.SECONDS)
        val bundle = intent.getBundleExtra(RESULT_BUNDLE)
        val termuxErr = bundle?.getInt(RESULT_ERR, android.app.Activity.RESULT_OK)
        val termuxMessage = bundle?.getString(RESULT_ERRMSG).orEmpty()
        val finalExitCode = active?.localExitCode ?: bundle?.getInt(RESULT_EXIT_CODE, 125) ?: 125
        val error = when {
            bundle == null -> "Termux returned no result. Confirm Termux is version 0.109 or newer and allow-external-apps is enabled."
            termuxErr != android.app.Activity.RESULT_OK -> termuxMessage.ifBlank { "Termux could not start or finish the command (error $termuxErr)." }
            termuxMessage.isNotBlank() -> termuxMessage
            else -> null
        }
        var stdoutTruncated = active?.stdoutTruncated ?: false
        var stderrTruncated = active?.stderrTruncated ?: false
        if (active != null && bundle != null) {
            val stdout = bundle.getString(RESULT_STDOUT).orEmpty()
            val stderr = bundle.getString(RESULT_STDERR).orEmpty()
            if (!active.stdoutConnected && stdout.isNotEmpty()) {
                val fallback = stdout.take(MAX_OUTPUT_CHARS_PER_STREAM)
                TermuxBridgeEvents.emit(mapOf("type" to "output", "requestId" to requestId, "channel" to "stdout", "chunk" to fallback))
                stdoutTruncated = stdout.length > fallback.length
            }
            if (!active.stderrConnected && stderr.isNotEmpty()) {
                val fallback = stderr.take(MAX_OUTPUT_CHARS_PER_STREAM)
                TermuxBridgeEvents.emit(mapOf("type" to "output", "requestId" to requestId, "channel" to "stderr", "chunk" to fallback))
                stderrTruncated = stderr.length > fallback.length
            }
        }
        TermuxBridgeEvents.emit(
            mapOf(
                "type" to "complete",
                "requestId" to requestId,
                "exitCode" to finalExitCode,
                "error" to error,
                "stdoutTruncated" to stdoutTruncated,
                "stderrTruncated" to stderrTruncated,
            ),
        )
        TermuxBridgeEvents.finish(requestId)
    }
}
