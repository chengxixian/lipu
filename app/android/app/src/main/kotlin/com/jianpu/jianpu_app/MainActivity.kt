package com.jianpu.jianpu_app

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * 离谱（Lipu）· 简谱识谱机
 *
 * 提供两个很轻的原生通道，避免为这些能力引入第三方插件：
 *  1. jianpu/dynamic_color —— 读取 Android 12+ 的 Material You 动态色
 *  2. jianpu/audio         —— 用 MediaExtractor + MediaCodec 把任意系统支持的
 *                             音频格式（mp3/m4a/aac/flac/ogg/wav…）解码成 PCM16 WAV，
 *                             供「听歌扒谱」做频谱分析
 */
class MainActivity : FlutterActivity() {
    private val colorChannel = "jianpu/dynamic_color"
    private val audioChannel = "jianpu/audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, colorChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSystemSeed" -> result.success(systemSeedColor())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decodeToWav" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "缺少 path 参数", null)
                            return@setMethodCallHandler
                        }
                        // 解码可能持续数秒，放到后台线程，结果回主线程返回
                        Thread {
                            var wavPath: String? = null
                            var error: String? = null
                            try {
                                wavPath = decodeToWav(path)
                            } catch (e: Exception) {
                                error = e.message ?: e.toString()
                            }
                            runOnUiThread {
                                if (wavPath != null) result.success(wavPath)
                                else result.error("decode_failed", error ?: "无法解码该音频文件", null)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** 取系统主色（system_accent1_500）；Android 12 以下返回 null，由 Dart 侧回退到种子色板 */
    private fun systemSeedColor(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return try {
            val id = resources.getIdentifier("system_accent1_500", "color", "android")
            if (id == 0) null else resources.getColor(id, theme)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 把音频文件解码为单声道/原始声道的 PCM16 WAV，返回文件路径。
     * Dart 侧会再做混音与重采样，这里保持原始声道数与采样率，避免重复处理。
     */
    private fun decodeToWav(path: String): String? {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)

        var trackIndex = -1
        var format: MediaFormat? = null
        for (i in 0 until extractor.trackCount) {
            val f = extractor.getTrackFormat(i)
            val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) {
                trackIndex = i
                format = f
                break
            }
        }
        if (trackIndex < 0 || format == null) {
            extractor.release()
            return null
        }
        extractor.selectTrack(trackIndex)

        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)

        val rawFile = File(cacheDir, "jianpu_decode.raw")
        val out = BufferedOutputStream(FileOutputStream(rawFile))
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        var totalBytes = 0L

        try {
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(10000)
                    if (inIndex >= 0) {
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, 10000)
                if (outIndex >= 0) {
                    val buffer: ByteBuffer = codec.getOutputBuffer(outIndex)!!
                    if (info.size > 0) {
                        val chunk = ByteArray(info.size)
                        buffer.position(info.offset)
                        buffer.get(chunk)
                        out.write(chunk)
                        totalBytes += info.size
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val nf = codec.outputFormat
                    channels = nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    sampleRate = nf.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                }
            }
        } finally {
            out.close()
            codec.stop()
            codec.release()
            extractor.release()
        }

        if (totalBytes <= 0) {
            rawFile.delete()
            return null
        }

        val wavFile = File(cacheDir, "jianpu_decoded.wav")
        writeWavHeader(wavFile, rawFile, channels, sampleRate, totalBytes)
        rawFile.delete()
        return wavFile.absolutePath
    }

    /** 给裸 PCM 数据加上 44 字节 WAV 头 */
    private fun writeWavHeader(wav: File, raw: File, channels: Int, sampleRate: Int, dataBytes: Long) {
        val byteRate = sampleRate * channels * 2
        RandomAccessFile(wav, "rw").use { f ->
            f.setLength(0)
            f.writeBytes("RIFF")
            f.write(intToLe(36 + dataBytes.toInt()))
            f.writeBytes("WAVE")
            f.writeBytes("fmt ")
            f.write(intToLe(16))
            f.write(shortToLe(1)) // PCM
            f.write(shortToLe(channels))
            f.write(intToLe(sampleRate))
            f.write(intToLe(byteRate))
            f.write(shortToLe(channels * 2))
            f.write(shortToLe(16))
            f.writeBytes("data")
            f.write(intToLe(dataBytes.toInt()))
            // RandomAccessFile 不是 OutputStream，这里手动搬运
            val buffer = ByteArray(1 shl 16)
            raw.inputStream().use { input ->
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    f.write(buffer, 0, read)
                }
            }
        }
    }

    private fun intToLe(v: Int): ByteArray = byteArrayOf(
        (v and 0xFF).toByte(),
        ((v shr 8) and 0xFF).toByte(),
        ((v shr 16) and 0xFF).toByte(),
        ((v shr 24) and 0xFF).toByte(),
    )

    private fun shortToLe(v: Int): ByteArray =
        byteArrayOf((v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte())
}
