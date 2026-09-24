package com.happydrive.app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File

/**
 * Re-encodes a sound file as AAC in an .m4a, with the phone's own codecs.
 *
 * Decoded sound goes straight from the decoder into the encoder a buffer at
 * a time, so memory stays flat however long the recording is. Anything this
 * doesn't handle — more than two channels, float samples, a rate AAC can't
 * carry — returns false, and the original is kept.
 */
object AudioTranscoder {
    private const val AAC = MediaFormat.MIMETYPE_AUDIO_AAC
    private const val TIMEOUT_US = 10_000L

    /** Gives up on a file that has made no progress for this long. */
    private const val STALL_MS = 15_000L

    fun toAac(input: String, output: String, bitsPerChannel: Int): Boolean {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var ok = false
        try {
            extractor.setDataSource(input)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: return false
            extractor.selectTrack(track)
            val inFormat = extractor.getTrackFormat(track)
            val dec = MediaCodec.createDecoderByType(inFormat.getString(MediaFormat.KEY_MIME)!!)
            decoder = dec
            dec.configure(inFormat, null, null, 0)
            dec.start()

            val mux = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux
            var muxTrack = -1

            // The encoder is set up from what the decoder actually produces,
            // which can differ from what the file claims (HE-AAC doubles its
            // rate, some decoders turn mono into stereo).
            var enc: MediaCodec? = null
            var sampleRate = 0
            var channels = 0
            var framesQueued = 0L

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var decoderDone = false
            var encoderDone = false
            var lastProgress = System.currentTimeMillis()

            fun startEncoder(format: MediaFormat): Boolean {
                sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                if (format.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                    format.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT
                ) return false
                if (channels !in 1..2 || sampleRate !in 8000..48000) return false
                val out = MediaFormat.createAudioFormat(AAC, sampleRate, channels).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, bitsPerChannel * channels)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
                }
                val e = MediaCodec.createEncoderByType(AAC)
                enc = e
                encoder = e
                e.configure(out, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                e.start()
                return true
            }

            /** Moves whatever the encoder has finished into the file. */
            fun drainEncoder(wait: Boolean) {
                val e = enc ?: return
                while (!encoderDone) {
                    val index = e.dequeueOutputBuffer(info, if (wait) TIMEOUT_US else 0)
                    when {
                        index == MediaCodec.INFO_TRY_AGAIN_LATER -> return
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            muxTrack = mux.addTrack(e.outputFormat)
                            mux.start()
                            muxerStarted = true
                        }
                        index >= 0 -> {
                            val buffer = e.getOutputBuffer(index)!!
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                            if (info.size > 0 && muxerStarted) {
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                mux.writeSampleData(muxTrack, buffer, info)
                                lastProgress = System.currentTimeMillis()
                            }
                            e.releaseOutputBuffer(index, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) encoderDone = true
                        }
                    }
                }
            }

            /** Hands raw sound to the encoder, splitting it across buffers. */
            fun feedEncoder(pcm: java.nio.ByteBuffer, endOfStream: Boolean) {
                val e = enc ?: return
                val frameBytes = 2 * channels
                while (pcm.hasRemaining() || endOfStream) {
                    val index = e.dequeueInputBuffer(TIMEOUT_US)
                    if (index < 0) {
                        drainEncoder(false)
                        if (System.currentTimeMillis() - lastProgress > STALL_MS) {
                            throw IllegalStateException("encoder stalled")
                        }
                        continue
                    }
                    val buffer = e.getInputBuffer(index)!!
                    buffer.clear()
                    val take = minOf(pcm.remaining(), buffer.capacity() / frameBytes * frameBytes)
                    val slice = pcm.duplicate()
                    slice.limit(pcm.position() + take)
                    buffer.put(slice)
                    pcm.position(pcm.position() + take)
                    val timeUs = framesQueued * 1_000_000L / sampleRate
                    framesQueued += take / frameBytes
                    val last = endOfStream && !pcm.hasRemaining()
                    e.queueInputBuffer(
                        index, 0, take, timeUs,
                        if (last) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0,
                    )
                    lastProgress = System.currentTimeMillis()
                    if (last) return
                }
            }

            while (!encoderDone) {
                if (System.currentTimeMillis() - lastProgress > STALL_MS) return false

                if (!inputDone) {
                    val index = dec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = dec.getInputBuffer(index)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(index, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                        lastProgress = System.currentTimeMillis()
                    }
                }

                if (!decoderDone) {
                    val index = dec.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (enc == null && !startEncoder(dec.outputFormat)) return false
                        }
                        index >= 0 -> {
                            if (enc == null && !startEncoder(dec.outputFormat)) return false
                            val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            val pcm = dec.getOutputBuffer(index)!!
                            pcm.position(info.offset)
                            pcm.limit(info.offset + info.size)
                            feedEncoder(pcm, eos)
                            dec.releaseOutputBuffer(index, false)
                            if (eos) decoderDone = true
                        }
                    }
                }

                if (decoderDone && enc == null) return false
                drainEncoder(decoderDone)
            }
            ok = muxerStarted
        } catch (e: Exception) {
            ok = false
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            try { encoder?.stop() } catch (_: Exception) {}
            try { encoder?.release() } catch (_: Exception) {}
            try { if (muxerStarted) muxer?.stop() } catch (_: Exception) { ok = false }
            try { muxer?.release() } catch (_: Exception) {}
            extractor.release()
            if (!ok) File(output).delete()
        }
        // Decided only after the muxer has been closed, since that is when
        // the file is actually finished — and when it can still fail.
        return ok
    }
}
