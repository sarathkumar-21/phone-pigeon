package dev.phonepigeon

import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Keeps the last crash on disk so the next launch can show it. Lets someone report "the app closes" from a
 * device where no debugger is attached. Contains no message content, keys or numbers: only the stack trace and
 * device/app versions.
 */
object CrashReporter {
    private fun file(context: Context) = File(context.filesDir, "last_crash.txt")

    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                val trace = StringWriter().also { error.printStackTrace(PrintWriter(it)) }.toString().take(12_000)
                val version = runCatching { app.packageManager.getPackageInfo(app.packageName, 0).versionName }.getOrNull()
                file(app).writeText(
                    "PhonePigeon $version\n" +
                        "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), ${Build.MANUFACTURER} ${Build.MODEL}, ABIs ${Build.SUPPORTED_ABIS.joinToString()}\n" +
                        "Thread: ${thread.name}\n\n$trace"
                )
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun pending(context: Context): String? = runCatching { file(context).takeIf { it.exists() }?.readText() }.getOrNull()

    fun clear(context: Context) { runCatching { file(context).delete() } }
}
