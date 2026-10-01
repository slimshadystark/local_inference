package it.asfweb.local_inference_flutter

import android.os.BatteryManager
import android.os.PowerManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The pure parts of the probe, on the JVM: the SHA-256, the nearest existing folder, the name tables and the answer
 * of `network`.
 */
class DeviceProbeTest {
    @Test
    fun sha256HexReadsTheWholeFileInChunks() {
        val file = File.createTempFile("device_probe", ".bin")
        try {
            file.writeText("abc")
            assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", DeviceProbe.sha256Hex(file))
            // More than two 8 MB buffers: the chunked read must match a one-shot digest.
            file.writeBytes(ByteArray(17 * 1024 * 1024 + 5) { (it % 251).toByte() })
            val oneShot = java.security.MessageDigest.getInstance("SHA-256").digest(file.readBytes())
                .joinToString("") { "%02x".format(it) }
            assertEquals(oneShot, DeviceProbe.sha256Hex(file))
        } finally {
            file.delete()
        }
    }

    @Test
    fun existingFolderWalksUpToAFolderThatExists() {
        val root = Files.createTempDirectory("device_probe").toFile()
        try {
            val missing = File(root, "models/qwen/model.gguf.part")
            assertEquals(root, DeviceProbe.existingFolder(missing))
            assertEquals(root, DeviceProbe.existingFolder(root))
            assertNull(DeviceProbe.existingFolder(File("relative/that/does/not/exist")))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun networkStateCountsWifiOnlyWithAConnection() {
        assertEquals(mapOf("connected" to true, "wifi" to true), Network.stateOf(connected = true, wifi = true))
        assertEquals(mapOf("connected" to true, "wifi" to false), Network.stateOf(connected = true, wifi = false))
        assertEquals(mapOf("connected" to false, "wifi" to false), Network.stateOf(connected = false, wifi = true))
    }

    @Test
    fun thermalAndBatteryStatesUseTheNamesOfIos() {
        assertEquals("nominal", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_NONE))
        assertEquals("fair", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_LIGHT))
        assertEquals("fair", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_MODERATE))
        assertEquals("serious", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_SEVERE))
        assertEquals("critical", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_CRITICAL))
        assertEquals("critical", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_EMERGENCY))
        assertEquals("critical", Diagnostics.thermalStateName(PowerManager.THERMAL_STATUS_SHUTDOWN))
        assertEquals("unknown", Diagnostics.thermalStateName(99))
        assertEquals("charging", Diagnostics.batteryName(BatteryManager.BATTERY_STATUS_CHARGING))
        assertEquals("full", Diagnostics.batteryName(BatteryManager.BATTERY_STATUS_FULL))
        assertEquals("unplugged", Diagnostics.batteryName(BatteryManager.BATTERY_STATUS_DISCHARGING))
        assertEquals("unplugged", Diagnostics.batteryName(BatteryManager.BATTERY_STATUS_NOT_CHARGING))
        assertEquals("unknown", Diagnostics.batteryName(-1))
    }
}
