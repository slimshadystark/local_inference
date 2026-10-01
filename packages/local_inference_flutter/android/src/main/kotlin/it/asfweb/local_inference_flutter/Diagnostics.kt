package it.asfweb.local_inference_flutter

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager

/**
 * A snapshot of the conditions that change on-device speed: heat, battery saver, charging, and memory. The keys are
 * those of the iOS probe where Android has the value (machine, thermal_state, low_power_mode, battery,
 * physical_memory_mb), plus platform, android, os_version, sdk_int, is_simulator, android_thermal_status,
 * thermal_headroom, battery_percent, available_memory_mb, low_memory, low_memory_threshold_mb and process_pss_mb.
 */
object Diagnostics {
    fun snapshot(context: Context): Map<String, Any?> {
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val snapshot = mutableMapOf<String, Any?>(
            "platform" to "android",
            "machine" to machine(),
            "android" to Build.VERSION.RELEASE,
            "os_version" to Build.VERSION.RELEASE,
            "sdk_int" to Build.VERSION.SDK_INT,
            "is_simulator" to DeviceProbe.isEmulator(),
            "low_power_mode" to power.isPowerSaveMode,
            "physical_memory_mb" to memory.totalMem / DeviceProbe.MB,
            "available_memory_mb" to memory.availMem / DeviceProbe.MB,
            "low_memory" to memory.lowMemory,
            "low_memory_threshold_mb" to memory.threshold / DeviceProbe.MB,
            "process_pss_mb" to Debug.getPss() / 1024,
            "thermal_state" to "unknown",
            "battery" to "unknown",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val status = power.currentThermalStatus
            snapshot["thermal_state"] = thermalStateName(status)
            snapshot["android_thermal_status"] = status
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val headroom = runCatching { power.getThermalHeadroom(10) }.getOrNull()
            if (headroom != null && !headroom.isNaN()) snapshot["thermal_headroom"] = headroom.toDouble()
        }
        // The sticky battery broadcast: no receiver is registered.
        val battery = runCatching { context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) }
            .getOrNull()
        if (battery != null) {
            snapshot["battery"] = batteryName(battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1))
            val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            if (level >= 0 && scale > 0) snapshot["battery_percent"] = level * 100 / scale
        }
        return snapshot
    }

    /** PowerManager's thermal status as the names iOS uses: nominal, fair, serious, critical. */
    fun thermalStateName(status: Int): String = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> "nominal"
        PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> "fair"
        PowerManager.THERMAL_STATUS_SEVERE -> "serious"
        PowerManager.THERMAL_STATUS_CRITICAL,
        PowerManager.THERMAL_STATUS_EMERGENCY,
        PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
        else -> "unknown"
    }

    /** BatteryManager's status as the names iOS uses: charging, full, unplugged. */
    fun batteryName(status: Int): String = when (status) {
        BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
        BatteryManager.BATTERY_STATUS_FULL -> "full"
        BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "unplugged"
        else -> "unknown"
    }

    /** "Google Pixel 8 (Tensor G3)": the maker, the model and, on API 31+, the chip. */
    private fun machine(): String {
        val chip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null
        val parts = mutableListOf(Build.MANUFACTURER, Build.MODEL)
        if (chip != null && chip.isNotBlank() && chip != Build.UNKNOWN) parts.add("($chip)")
        return parts.joinToString(" ")
    }
}
