package dev.local.media_compressor

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class AndroidMediaBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.local.media_compressor/files")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val resolver = activity.contentResolver
    private val sources = mutableSetOf<String>()
    private val trees = mutableSetOf<String>()
    private val staged = mutableSetOf<String>()
    private val outstanding = mutableSetOf<MethodChannel.Result>()
    private var picker: Pair<Int, MethodChannel.Result>? = null
    private var stageCancellation: AtomicBoolean? = null
    private val fileRequest = 3101
    private val treeRequest = 3102

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/jpeg", "image/png", "image/webp", "video/mp4", "video/quicktime", "video/x-matroska"))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    launch(intent, fileRequest, result)
                }
                "folder" -> launch(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }, treeRequest, result)
                "prepare" -> {
                    val reference = call.argument<String>("reference")
                    if (reference == null || reference !in sources) {
                        result.error("permissionDenied", "Select the source file again.", mapOf("scope" to "item"))
                    } else {
                        val cancellation = AtomicBoolean(false)
                        stageCancellation = cancellation
                        run("item", result) {
                            val folder = File(activity.cacheDir, "media-compressor/staged")
                            if (!folder.isDirectory && !folder.mkdirs()) throw IOException("Cannot create the app cache.")
                            val file = File.createTempFile("input-", ".media", folder)
                            try {
                                val size = resolver.openInputStream(Uri.parse(reference))?.use { input ->
                                    FileOutputStream(file).use { output ->
                                        val buffer = ByteArray(256 * 1024)
                                        var bytes = 0L
                                        while (true) {
                                            if (cancellation.get() || Thread.currentThread().isInterrupted) throw CancellationException()
                                            val count = input.read(buffer)
                                            if (count < 0) break
                                            if (count > 0) { output.write(buffer, 0, count); bytes += count }
                                        }
                                        output.flush()
                                        bytes
                                    }
                                } ?: throw IOException("Cannot read this source file.")
                                if (size == 0L) throw IOException("The source file is empty.")
                                synchronized(staged) { staged.add(file.absolutePath) }
                                mapOf("path" to file.absolutePath, "sizeBytes" to size)
                            } catch (error: Exception) {
                                file.delete()
                                throw error
                            } finally {
                                main.post { if (stageCancellation === cancellation) stageCancellation = null }
                            }
                        }
                    }
                }
                "cancelPrepare" -> { stageCancellation?.set(true); result.success(null) }
                "release" -> {
                    val path = call.argument<String>("path")
                    run("operation", result) {
                        if (path == null || !synchronized(staged) { path in staged }) throw SecurityException("This staged input is not owned by the app.")
                        val file = File(path)
                        if (file.exists() && !file.delete()) throw IOException("Could not remove the staged input.")
                        synchronized(staged) { staged.remove(path) }
                        emptyMap<String, Any>()
                    }
                }
                "save" -> {
                    val folder = call.argument<String>("folder")
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    val mime = call.argument<String>("mimeType")
                    if (folder == null || folder !in trees || path == null || name == null || mime == null) {
                        result.error("permissionDenied", "Choose the output folder again.", mapOf("scope" to "destination"))
                    } else {
                        run("destination", result) { save(folder, path, name, mime) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun launch(intent: Intent, code: Int, result: MethodChannel.Result) {
        if (picker != null) {
            result.error("busy", "A file picker is already open.", mapOf("scope" to "operation"))
            return
        }
        picker = code to result
        outstanding.add(result)
        try {
            activity.startActivityForResult(intent, code)
        } catch (error: Exception) {
            picker = null
            outstanding.remove(result)
            result.error("unavailable", "Cannot open the Android picker: ${error.message}", mapOf("scope" to "operation"))
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val pending = picker ?: return false
        if (pending.first != requestCode) return false
        picker = null
        val result = pending.second
        if (resultCode != Activity.RESULT_OK || data == null) {
            outstanding.remove(result)
            result.success(null)
            return true
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri) }
        data.data?.let { if (it !in uris) uris.add(it) }
        if (requestCode == treeRequest) {
            val uri = uris.firstOrNull()
            if (uri == null) {
                outstanding.remove(result)
                result.success(null)
            } else if (data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) !=
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
                outstanding.remove(result)
                result.error("permissionDenied", "Choose a folder that grants read and write access.", mapOf("scope" to "destination"))
            } else {
                trees.add(uri.toString())
                run("destination", result) {
                    val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                    mapOf("reference" to uri.toString(), "displayName" to metadata(document).first)
                }
            }
        } else {
            uris.forEach { sources.add(it.toString()) }
            run("operation", result) {
                val selected = mutableListOf<Map<String, Any?>>()
                val errors = mutableListOf<Map<String, Any?>>()
                for (uri in uris.distinct()) {
                    try {
                        if (uri.scheme != "content") throw IOException("The picker did not return a document reference.")
                        val (name, size) = metadata(uri)
                        val kind = when (name.substringAfterLast('.', "").lowercase(Locale.ROOT)) {
                            "jpg", "jpeg", "png", "webp" -> "image"
                            "mp4", "mov", "mkv" -> "video"
                            else -> null
                        }
                        if (kind == null || size == 0L) {
                            errors.add(mapOf("reference" to uri.toString(), "message" to "$name: ${if (size == 0L) "empty file" else "unsupported file type"}.", "code" to if (size == 0L) "empty" else "unsupported"))
                        } else {
                            selected.add(mapOf("reference" to uri.toString(), "displayName" to name, "kind" to kind, "sizeBytes" to size))
                        }
                    } catch (error: Exception) {
                        errors.add(mapOf("reference" to uri.toString(), "message" to "Cannot read the selected file: ${error.message}", "code" to "unreadable"))
                    }
                }
                mapOf("sources" to selected, "errors" to errors)
            }
        }
        return true
    }

    private fun metadata(uri: Uri): Pair<String, Long?> {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val size = cursor.getColumnIndex(OpenableColumns.SIZE)
                return (if (name >= 0 && !cursor.isNull(name)) cursor.getString(name) else "Selected file") to
                    (if (size >= 0 && !cursor.isNull(size)) cursor.getLong(size).takeIf { it >= 0 } else null)
            }
        }
        throw IOException("The document provider did not supply file information.")
    }

    private fun save(folder: String, path: String, name: String, mime: String): Map<String, Any> {
        if (name.isBlank() || name == "." || name == ".." || name.any { it == '/' || it == '\\' || it < ' ' }) throw IOException("The output name is not safe.")
        val source = File(path)
        if (!source.canonicalPath.startsWith(activity.cacheDir.canonicalPath + File.separator) || !source.isFile || source.length() == 0L) throw IOException("The completed app output is unavailable.")
        val tree = Uri.parse(folder)
        val parentId = DocumentsContract.getTreeDocumentId(tree)
        val existing = mutableSetOf<String>()
        resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId), arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) existing.add(cursor.getString(0))
        } ?: throw IOException("Cannot inspect the output folder safely.")
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
        val created = DocumentsContract.createDocument(resolver, parent, mime, name) ?: throw IOException("Cannot create a new output document.")
        if (DocumentsContract.getDocumentId(created) in existing) throw IOException("The provider returned an existing document; nothing was written.")
        try {
            val bytes = source.inputStream().use { input ->
                resolver.openOutputStream(created, "w")?.use { output ->
                    val size = input.copyTo(output, 256 * 1024)
                    output.flush()
                    size
                } ?: throw IOException("Cannot write the new output document.")
            }
            val actualName = metadata(created).first
            return mapOf("reference" to created.toString(), "displayName" to actualName, "sizeBytes" to bytes)
        } catch (error: Exception) {
            val deleted = try { DocumentsContract.deleteDocument(resolver, created) } catch (_: Exception) { false }
            if (!deleted) throw IOException("${error.message} A partial new output may remain at $created.", error)
            throw error
        }
    }

    private fun run(scope: String, result: MethodChannel.Result, action: () -> Any) {
        outstanding.add(result)
        worker.execute {
            try {
                val value = action()
                main.post { if (outstanding.remove(result)) result.success(value) }
            } catch (_: CancellationException) {
                main.post { if (outstanding.remove(result)) result.success(null) }
            } catch (error: Exception) {
                val code = when {
                    error is SecurityException -> "permissionDenied"
                    error.message?.contains("ENOSPC", true) == true -> "noSpace"
                    error.message?.contains("app cache", true) == true -> "unavailable"
                    error.message?.contains("empty", true) == true -> "empty"
                    else -> "io"
                }
                main.post { if (outstanding.remove(result)) result.error(code, error.message ?: "Android file operation failed.", mapOf("scope" to scope)) }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        stageCancellation?.set(true)
        picker = null
        outstanding.toList().forEach { it.error("unavailable", "The Android file operation was closed.", mapOf("scope" to "operation")) }
        outstanding.clear()
        worker.shutdownNow()
    }
}
