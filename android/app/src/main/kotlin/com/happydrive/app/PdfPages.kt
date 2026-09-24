package com.happydrive.app

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Draws PDF pages with Android's own renderer, for the in-app preview.
 *
 * The document stays open between pages, since the viewer asks for them one
 * after another as they scroll into view; [close] lets it go. Everything
 * here runs on one worker thread, which PdfRenderer requires.
 */
class PdfPages {
    private var path: String? = null
    private var file: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null

    private fun open(path: String): PdfRenderer {
        renderer?.let { if (this.path == path) return it }
        close()
        val fd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        val r = try {
            PdfRenderer(fd)
        } catch (e: Exception) {
            fd.close()
            throw e
        }
        this.path = path
        file = fd
        renderer = r
        return r
    }

    fun pageCount(path: String): Int = open(path).pageCount

    /** Page [index] as a JPEG [width] pixels wide, on white. */
    fun render(path: String, index: Int, width: Int): ByteArray {
        val r = open(path)
        r.openPage(index).use { page ->
            val height = (width.toLong() * page.height / page.width).toInt().coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            try {
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
                return out.toByteArray()
            } finally {
                bitmap.recycle()
            }
        }
    }

    fun close() {
        try { renderer?.close() } catch (_: Exception) {}
        try { file?.close() } catch (_: Exception) {}
        renderer = null
        file = null
        path = null
    }
}
