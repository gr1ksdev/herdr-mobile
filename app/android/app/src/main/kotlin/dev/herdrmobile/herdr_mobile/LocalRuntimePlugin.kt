package dev.herdrmobile.herdr_mobile

import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import com.thothterm.Process as TermProcess
import com.thothterm.TermIO
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException

/**
 * The PTY side of the local Debian runtime, adapted from ThothTerm's
 * `libtermexec` (Apache-2.0). This first slice runs the Android shell as a
 * spike: it proves the byte pipeline before the PRoot/rootfs port lands.
 *
 * Only the process this plugin created is ever killed, by the PID returned
 * from `createSubprocess`. No name or pattern kills, ever.
 */
class LocalRuntimePlugin : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pty: ParcelFileDescriptor? = null
    private var readPty: ParcelFileDescriptor? = null
    private var writePty: ParcelFileDescriptor? = null
    private var input: FileOutputStream? = null
    private var reader: Thread? = null
    private var pid = -1

    @Volatile
    private var running = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> result.success(null) // rootfs download lands with the PRoot port
            "start" -> try {
                start()
                result.success(PANE_ID)
            } catch (e: Exception) {
                result.error("start", e.message, null)
            }
            "write" -> {
                val out = input
                val bytes = call.argument<ByteArray>("bytes")
                when {
                    out == null -> result.error("write", "The local terminal is not running", null)
                    bytes == null -> result.error("write", "No bytes to write", null)
                    else -> try {
                        out.write(bytes)
                        out.flush()
                        result.success(null)
                    } catch (e: IOException) {
                        result.error("write", e.message, null)
                    }
                }
            }
            "resize" -> {
                val master = pty
                val rows = call.argument<Int>("rows")
                val cols = call.argument<Int>("cols")
                when {
                    master == null -> result.error("resize", "The local terminal is not running", null)
                    rows == null || cols == null -> result.error("resize", "Missing size", null)
                    else -> try {
                        TermIO.setWindowSize(master, rows, cols)
                        result.success(null)
                    } catch (e: IOException) {
                        result.error("resize", e.message, null)
                    }
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start() {
        if (running) return
        val master = ParcelFileDescriptor.open(File("/dev/ptmx"), ParcelFileDescriptor.MODE_READ_WRITE)
        try {
            TermIO.setUTF8Input(master, true)
            TermIO.setWindowSize(master, 24, 80)
            // Spike only: replaced by GardenRuntime.buildArgv() (PRoot + rootfs).
            val command = "/system/bin/sh"
            val argv = arrayOf(command)
            val env = arrayOf(
                "HOME=/data/local/tmp",
                "PATH=/system/bin:/system/xbin",
                "TERM=xterm-256color",
            )
            val child = TermProcess.createSubprocess(master, command, argv, env)
            if (child <= 0) throw IOException("Could not start the local shell")
            // From here on, a failure must end the process we just created.
            // Closing a stream closes its fd, so the two streams get duplicates
            // and only `pty` owns the original master fd.
            var createdChild = child
            try {
                val reads = master.dup()
                val writes = master.dup()
                readPty = reads
                writePty = writes
                pty = master
                input = FileOutputStream(writes.fileDescriptor)
                val source = FileInputStream(reads.fileDescriptor)
                pid = child
                createdChild = -1
                running = true
                reader = Thread(
                    {
                        val buffer = ByteArray(8192)
                        try {
                            while (running) {
                                val count = source.read(buffer)
                                if (count <= 0) break
                                val chunk = buffer.copyOf(count)
                                main.post { sink?.success(chunk) }
                            }
                        } catch (e: IOException) {
                            if (running) main.post { sink?.error("pty", e.message, null) }
                        } finally {
                            try {
                                source.close()
                            } catch (_: IOException) {
                            }
                            if (running) {
                                running = false
                                main.post { sink?.endOfStream() }
                            }
                        }
                    },
                    "herdr-local-pty",
                ).apply {
                    isDaemon = true
                    start()
                }
            } catch (e: Exception) {
                if (createdChild > 0) TermProcess.killChilds(createdChild)
                try {
                    readPty?.close()
                } catch (_: IOException) {
                }
                try {
                    writePty?.close()
                } catch (_: IOException) {
                }
                readPty = null
                writePty = null
                input = null
                pty = null
                throw e
            }
        } catch (e: Exception) {
            try {
                master.close()
            } catch (_: IOException) {
            }
            throw e
        }
    }

    private fun stop() {
        running = false
        val child = pid
        if (child > 0) TermProcess.killChilds(child)
        pid = -1
        try {
            input?.close()
        } catch (_: IOException) {
        }
        input = null
        try {
            readPty?.close()
        } catch (_: IOException) {
        }
        try {
            writePty?.close()
        } catch (_: IOException) {
        }
        readPty = null
        writePty = null
        try {
            pty?.close()
        } catch (_: IOException) {
        }
        pty = null
        reader?.interrupt()
        reader = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        // The foreground service owns the shell: looking away must not end it.
        sink = null
    }

    companion object {
        const val PANE_ID = "local-p1"
    }
}
