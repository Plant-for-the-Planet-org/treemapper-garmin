package org.plantfortheplanet.treemapper.garmindemo

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Catches exceptions that kill a thread and keeps them across a restart.
 *
 * The Garmin SDK reads the ADB socket on its own thread. If that thread throws,
 * the exception never reaches this app's code and the connection dies with it,
 * which the Connect IQ simulator reports only as
 * "Socket Error in packet header 0". If the whole process goes down, the in-app
 * log pane goes with it and there is nothing left to read.
 *
 * So: record the stack trace to a file the moment it happens, and print it into
 * the log pane on the next start. The thread's name is the useful part. A
 * Garmin thread name means the fault is inside the SDK, not in this app.
 *
 * This does not swallow anything. The previous handler still runs, so Android
 * still reports the crash as it normally would.
 */
object CrashLog {

    private const val FILE = "last-crash.txt"
    private val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.UK)

    fun install(context: Context) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        val appContext = context.applicationContext

        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val trace = StringWriter()
                error.printStackTrace(PrintWriter(trace))
                val entry = buildString {
                    append(stamp.format(Date())).append('\n')
                    append("thread: ").append(thread.name)
                    append("  (id ").append(thread.id).append(")\n")
                    append(trace.toString())
                }
                File(appContext.filesDir, FILE).appendText(entry + "\n")
            } catch (ignored: Throwable) {
                // Never let the recorder hide the original failure.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** Anything recorded since the last read, then forgotten. */
    fun drain(context: Context): String? {
        val file = File(context.filesDir, FILE)
        if (!file.exists()) return null
        val text = try { file.readText() } catch (e: Throwable) { null }
        file.delete()
        return if (text.isNullOrBlank()) null else text
    }
}
