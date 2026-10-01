package it.asfweb.local_inference_flutter

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import android.os.StatFs
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

/** What the model download needs from the device: the platform, memory and disk figures, and a file's SHA-256. */
object DeviceProbe {
    const val MB = 1024L * 1024L

    /** The OS version and SDK level, the ABIs, whether the process is 64-bit and whether it runs in an emulator. */
    fun platformInfo(): Map<String, Any?> = mapOf(
        "apiVersion" to 1,
        "os" to "android",
        "osVersion" to Build.VERSION.RELEASE,
        "sdkInt" to Build.VERSION.SDK_INT,
        "abis" to Build.SUPPORTED_ABIS.toList(),
        "is64Bit" to Process.is64Bit(),
        "isSimulator" to isEmulator(),
    )

    /** Total and available RAM, and free space on the volume of [path] (default: filesDir), in MB. */
    fun capabilities(context: Context, path: String?): Map<String, Any> {
        val memory = ActivityManager.MemoryInfo()
        (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        val caps = mutableMapOf<String, Any>(
            "physicalMemoryMB" to memory.totalMem / MB,
            "availableMemoryMB" to memory.availMem / MB,
        )
        val volume = existingFolder(if (path == null) context.filesDir else File(path))
        if (volume != null) {
            runCatching { StatFs(volume.absolutePath).availableBytes / MB }.onSuccess { caps["freeDiskMB"] = it }
        }
        return caps
    }

    /** Lowercase hex SHA-256, reading 8 MB at a time. */
    fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8 * 1024 * 1024)
        FileInputStream(file).use { input ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** [file] or its nearest existing parent; null when none exists. */
    fun existingFolder(file: File): File? {
        var current: File? = file
        while (current != null && !current.exists()) current = current.parentFile
        return current
    }

    fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.MODEL.contains("sdk_gphone") ||
            Build.HARDWARE == "goldfish" ||
            Build.HARDWARE == "ranchu"
}
