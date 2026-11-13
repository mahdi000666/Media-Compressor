package dev.local.media_compressor

import android.os.Handler
import android.os.Looper
import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.FFmpegKitConfig
import com.antonkarpenko.ffmpegkit.LogRedirectionStrategy
import com.antonkarpenko.ffmpegkit.ReturnCode
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class AndroidFfmpegBridge(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.local.media_compressor/ffmpeg")
    private val main = Handler(Looper.getMainLooper())
    private data class Request(val id: Int, val result: MethodChannel.Result) {
        var sessionId: Long? = null
        var cancelled = false
    }
    private var active: Request? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "encode" -> {
                    val id = call.argument<Int>("id")
                    val arguments = call.argument<List<String>>("arguments")
                    if (id == null || arguments.isNullOrEmpty()) {
                        result.error("invalid", "Missing encoding arguments.", null)
                    } else if (active != null) {
                        result.error("busy", "An Android encode is already running.", null)
                    } else {
                        encode(Request(id, result), arguments)
                    }
                }
                "cancel" -> {
                    active?.takeIf { it.id == call.argument<Int>("id") }?.let { request ->
                        request.cancelled = true
                        request.sessionId?.let { FFmpegKit.cancel(it) }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun encode(request: Request, arguments: List<String>) {
        active = request
        val errors = StringBuilder()
        try {
            FFmpegKitConfig.setSessionHistorySize(1)
            FFmpegKitConfig.setLogRedirectionStrategy(LogRedirectionStrategy.NEVER_PRINT_LOGS)
            val session = FFmpegKit.executeWithArgumentsAsync(arguments.toTypedArray(), { completed ->
                main.post {
                    if (active === request) {
                        active = null
                        val message = synchronized(errors) { errors.toString() }
                        request.result.success(mapOf(
                            "code" to (completed.returnCode?.value ?: -1),
                            "cancelled" to (request.cancelled || ReturnCode.isCancel(completed.returnCode)),
                            "errors" to message.ifBlank { completed.failStackTrace?.takeLast(4096) ?: "" }
                        ))
                    }
                }
            }, { log ->
                synchronized(errors) {
                    errors.append(log.message)
                    if (errors.length > 4096) errors.delete(0, errors.length - 4096)
                }
            }, { statistics ->
                main.post {
                    if (active === request && !request.cancelled) {
                        channel.invokeMethod("progress", mapOf("id" to request.id, "microseconds" to (statistics.time * 1000).toLong()))
                    }
                }
            })
            request.sessionId = session.sessionId
            if (request.cancelled) FFmpegKit.cancel(session.sessionId)
        } catch (error: Exception) {
            active = null
            request.result.error("unavailable", "Cannot start Android FFmpeg: ${error.message}", null)
        } catch (error: LinkageError) {
            active = null
            request.result.error("unavailable", "Android encoder libraries could not load: ${error.message}", null)
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        active?.let { request ->
            request.sessionId?.let { FFmpegKit.cancel(it) }
            request.result.error("unavailable", "The Android encoder was closed.", null)
        }
        active = null
    }
}
