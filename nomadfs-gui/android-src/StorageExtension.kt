package net.nomadfs.app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import dev.oriel.OrielAppExtension
import dev.oriel.OrielCall
import dev.oriel.OrielExtensionError
import org.json.JSONObject

/**
 * Shared storage for NomadFS: whether the app may read folders such as
 * DCIM/Camera (Android 11+ "All files access"), the settings page that
 * grants it, and where the standard folders are.
 */
class StorageExtension : OrielAppExtension {
    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        val out = JSONObject()
        when (method) {
            "status" -> out.put("granted", granted())
            "request" -> {
                val ctx = call.context
                val intent = if (Build.VERSION.SDK_INT >= 30) {
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${ctx.packageName}"))
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
                }
                val activity = call.activity
                if (activity != null) {
                    call.runOnUi { activity.startActivity(intent) }
                } else {
                    ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                out.put("opened", true)
            }
            "info" -> {
                val root = Environment.getExternalStorageDirectory().absolutePath
                out.put("granted", granted())
                out.put("model", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
                out.put("storage", root)
                out.put("camera", "$root/${Environment.DIRECTORY_DCIM}/Camera")
                out.put("pictures", "$root/${Environment.DIRECTORY_PICTURES}")
                out.put("documents", "$root/${Environment.DIRECTORY_DOCUMENTS}")
                out.put("downloads", "$root/${Environment.DIRECTORY_DOWNLOADS}")
            }
            else -> throw OrielExtensionError("unknown_method", "no method $method")
        }
        return out.toString().toByteArray()
    }

    private fun granted(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager() else true
}
