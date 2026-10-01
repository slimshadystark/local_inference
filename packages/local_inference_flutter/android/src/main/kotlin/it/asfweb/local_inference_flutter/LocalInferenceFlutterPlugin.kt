package it.asfweb.local_inference_flutter

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The device probe of local_inference_flutter: the methods of `local_inference_flutter/device` (platform,
 * capabilities, sha256, excludeFromBackup, noBackupDirectory, network, diagnostics) and the thermal states of
 * `local_inference_flutter/thermal`.
 */
class LocalInferenceFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private var methods: MethodChannel? = null
    private var thermal: EventChannel? = null
    private var hashing: ExecutorService? = null
    private val mainThread = Handler(Looper.getMainLooper())

    /** A PowerManager.OnThermalStatusChangedListener while Dart listens (API 29+). */
    private var thermalListener: Any? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        // Hashes run one at a time, off the main thread.
        hashing = Executors.newSingleThreadExecutor()
        methods = MethodChannel(binding.binaryMessenger, "local_inference_flutter/device").also {
            it.setMethodCallHandler(this)
        }
        thermal = EventChannel(binding.binaryMessenger, "local_inference_flutter/thermal").also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        thermal?.setStreamHandler(null)
        onCancel(null)
        hashing?.shutdown()
        hashing = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "platform" -> result.success(DeviceProbe.platformInfo())
            "capabilities" -> result.success(DeviceProbe.capabilities(context, call.argument<String>("path")))
            "sha256" -> {
                val path = call.argument<String>("path")
                val executor = hashing
                when {
                    path == null -> result.error("bad_args", "path missing", null)
                    executor == null -> result.error("sha256_failed", "the plugin is detached", null)
                    // A 3 GB file takes seconds: hash on the background thread, answer on the main one.
                    else -> executor.execute {
                        val hex = runCatching { DeviceProbe.sha256Hex(File(path)) }
                        mainThread.post {
                            hex.fold(
                                { result.success(it) },
                                { result.error("sha256_failed", it.message, null) },
                            )
                        }
                    }
                }
            }
            // Models go to noBackupFilesDir (noBackupDirectory), which no backup includes; the path is still required.
            "excludeFromBackup" -> when (call.argument<String>("path")) {
                null -> result.error("bad_args", "path missing", null)
                else -> result.success(null)
            }
            "noBackupDirectory" -> result.success(context.noBackupFilesDir.absolutePath)
            "network" -> result.success(Network.state(context))
            "diagnostics" -> result.success(Diagnostics.snapshot(context))
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        // Registering the listener may report the current state again; Dart drops repeats.
        events.success(Diagnostics.thermalStateName(power.currentThermalStatus))
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            events.success(Diagnostics.thermalStateName(status))
        }
        power.addThermalStatusListener(context.mainExecutor, listener)
        thermalListener = listener
    }

    override fun onCancel(arguments: Any?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val listener = thermalListener as? PowerManager.OnThermalStatusChangedListener
            if (listener != null) {
                (context.getSystemService(Context.POWER_SERVICE) as PowerManager).removeThermalStatusListener(listener)
            }
        }
        thermalListener = null
    }
}
