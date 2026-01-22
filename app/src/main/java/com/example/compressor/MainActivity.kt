package com.example.mediacompressor

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.arthenica.ffmpegkit.FFmpegKit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class MainActivity : AppCompatActivity() {
    private lateinit var listView: ListView
    private lateinit var qualitySlider: SeekBar
    private lateinit var qualityLabel: TextView
    private lateinit var compressBtn: Button
    private lateinit var progressBar: ProgressBar

    private val fileList = mutableListOf<FileTask>()
    private val adapter by lazy {
        ArrayAdapter(
            this,
            android.R.layout.simple_list_item_1,
            fileList.map { it.displayName })
    }

    private val filePicker =
        registerForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
            uris?.forEach { uri ->
                if (fileList.size < MAX_FILES) {
                    addFile(uri)
                }
            }
            updateListView()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        checkPermissions()
        initViews()
        setupListeners()
    }

    private fun initViews() {
        listView = findViewById(R.id.listView)
        qualitySlider = findViewById(R.id.qualitySlider)
        qualityLabel = findViewById(R.id.qualityLabel)
        compressBtn = findViewById(R.id.compressBtn)
        progressBar = findViewById(R.id.progressBar)

        listView.adapter = adapter
        qualitySlider.max = 99
        qualitySlider.progress = 74
        updateQualityLabel()
    }

    private fun setupListeners() {
        findViewById<Button>(R.id.addFilesBtn).setOnClickListener {
            if (fileList.size >= MAX_FILES) {
                Toast.makeText(this, "Maximum $MAX_FILES files allowed", Toast.LENGTH_SHORT).show()
            } else {
                filePicker.launch("*/*")
            }
        }

        findViewById<Button>(R.id.clearBtn).setOnClickListener {
            fileList.clear()
            updateListView()
        }

        qualitySlider.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                updateQualityLabel()
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {}
            override fun onStopTrackingTouch(seekBar: SeekBar?) {}
        })

        compressBtn.setOnClickListener { startCompression() }
    }

    private fun checkPermissions() {
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) != PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                ), PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun addFile(uri: Uri) {
        val fileName = getFileName(uri)
        val fileType = getFileType(fileName)
        fileList.add(FileTask(uri, fileName, fileType))
    }

    private fun getFileName(uri: Uri): String {
        var name = "unknown"
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) name = cursor.getString(idx)
            }
        }
        return name
    }

    private fun getFileType(fileName: String): FileType {
        return when (fileName.substringAfterLast('.').lowercase()) {
            "jpg", "jpeg", "png", "webp" -> FileType.IMAGE
            "gif" -> FileType.GIF
            "mp4", "webm" -> FileType.VIDEO
            else -> FileType.UNKNOWN
        }
    }

    private fun updateListView() {
        adapter.clear()
        adapter.addAll(fileList.map { it.displayName })
        adapter.notifyDataSetChanged()
    }

    private fun updateQualityLabel() {
        qualityLabel.text = "${qualitySlider.progress + 1}"
    }

    private fun startCompression() {
        if (fileList.isEmpty()) return

        compressBtn.isEnabled = false
        progressBar.max = fileList.size
        progressBar.progress = 0

        lifecycleScope.launch {
            fileList.forEachIndexed { index, task ->
                compressFile(task)
                withContext(Dispatchers.Main) {
                    progressBar.progress = index + 1
                }
            }

            withContext(Dispatchers.Main) {
                compressBtn.isEnabled = true
                Toast.makeText(this@MainActivity, "Compression complete!", Toast.LENGTH_SHORT)
                    .show()
            }
        }
    }

    private suspend fun compressFile(task: FileTask) = withContext(Dispatchers.IO) {
        val quality = qualitySlider.progress + 1

        when (task.type) {
            FileType.IMAGE -> compressImage(task, quality)
            FileType.VIDEO -> compressVideo(task, quality)
            FileType.GIF -> compressGif(task, quality)
            else -> {}
        }
    }

    private fun compressImage(task: FileTask, quality: Int) {
        val inputFile = copyUriToCache(task.uri, task.displayName)
        val outputFile = File(
            getExternalFilesDir(null),
            task.displayName.replaceBeforeLast(
                '.',
                task.displayName.substringBeforeLast('.') + "_compressed"
            )
        )

        val cmd = "-i ${inputFile.absolutePath} -q:v $quality ${outputFile.absolutePath}"
        FFmpegKit.execute(cmd)

        inputFile.delete()
    }

    private fun compressVideo(task: FileTask, quality: Int) {
        val inputFile = copyUriToCache(task.uri, task.displayName)
        val outputFile = File(
            getExternalFilesDir(null),
            task.displayName.replaceBeforeLast(
                '.',
                task.displayName.substringBeforeLast('.') + "_compressed"
            )
        )

        val bitrate = (2000 * (quality / 100.0)).toInt()
        val cmd =
            "-i ${inputFile.absolutePath} -c:v libx264 -b:v ${bitrate}k -c:a aac -b:a 128k ${outputFile.absolutePath}"

        FFmpegKit.execute(cmd)
        inputFile.delete()
    }

    private fun compressGif(task: FileTask, quality: Int) {
        val inputFile = copyUriToCache(task.uri, task.displayName)
        val outputName = task.displayName.substringBeforeLast('.') + "_compressed.gif"
        val outputFile = File(getExternalFilesDir(null), outputName)

        val scaleFactor = 0.25 + (quality / 100.0) * 0.75
        val fps = when {
            quality < 30 -> 10
            quality < 60 -> 15
            else -> 25
        }

        val cmd =
            "-i ${inputFile.absolutePath} -vf scale=iw*$scaleFactor:ih*$scaleFactor,fps=$fps ${outputFile.absolutePath}"

        FFmpegKit.execute(cmd)
        inputFile.delete()
    }

    private fun copyUriToCache(uri: Uri, fileName: String): File {
        val cacheFile = File(cacheDir, fileName)
        contentResolver.openInputStream(uri)?.use { input ->
            cacheFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        return cacheFile
    }

    companion object {
        private const val MAX_FILES = 10
        private const val PERMISSION_REQUEST_CODE = 100
    }
}

data class FileTask(
    val uri: Uri,
    val displayName: String,
    val type: FileType
)

enum class FileType {
    IMAGE, VIDEO, GIF, UNKNOWN
}