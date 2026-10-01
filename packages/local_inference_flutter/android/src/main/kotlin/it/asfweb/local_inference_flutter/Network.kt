package it.asfweb.local_inference_flutter

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * The connection in use, for the Wi-Fi-only rule of the model download on background_downloader 9.5.9, which reads
 * `requiresWiFi` as "unmetered" and so lets an unmetered mobile network through (9.6 asks for Wi-Fi itself).
 */
object Network {
    /**
     * `connected` (a network with internet access) and `wifi` (that network goes over Wi-Fi), or null when the
     * system does not say. ACCESS_NETWORK_STATE comes with WorkManager, which background_downloader uses.
     */
    fun state(context: Context): Map<String, Boolean>? {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
        return try {
            val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
            stateOf(
                connected = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true,
                wifi = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true,
            )
        } catch (e: SecurityException) {
            null
        }
    }

    /** The answer Dart reads: Wi-Fi counts only with a connection. */
    fun stateOf(connected: Boolean, wifi: Boolean): Map<String, Boolean> =
        mapOf("connected" to connected, "wifi" to (connected && wifi))
}
