package com.kotodl.kotodl

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer

/** MPEG-TS -> MP4 without re-encoding, the job ffmpeg's `-c copy` does on desktop. */
object Remuxer {
    fun remux(src: String, dest: String) {
        val part = File("$dest.part")
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var ok = false
        try {
            extractor.setDataSource(src)
            muxer = MediaMuxer(part.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val tracks = HashMap<Int, Int>() // extractor track -> muxer track
            var video = false
            var audio = false
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val isVideo = mime.startsWith("video/")
                if (isVideo && !video || mime.startsWith("audio/") && !audio) {
                    if (isVideo) video = true else audio = true
                    extractor.selectTrack(i)
                    tracks[i] = muxer.addTrack(format)
                }
            }
            if (tracks.isEmpty()) throw IOException("No audio or video track")
            muxer.start()
            val buffer = ByteBuffer.allocateDirect(8 shl 20)
            val info = MediaCodec.BufferInfo()
            var base = -1L // samples come in time order, so the first is the earliest
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val time = extractor.sampleTime
                if (base < 0) base = time
                val key = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                info.set(0, size, maxOf(0L, time - base), if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                muxer.writeSampleData(tracks.getValue(extractor.sampleTrackIndex), buffer, info)
                extractor.advance()
            }
            muxer.stop()
            ok = true
        } finally {
            extractor.release()
            try {
                muxer?.release()
            } catch (e: IllegalStateException) {
                // stop() already failed; release() may complain too
            }
            if (!ok) part.delete()
        }
        if (!part.renameTo(File(dest))) throw IOException("Can't save $dest")
    }
}
