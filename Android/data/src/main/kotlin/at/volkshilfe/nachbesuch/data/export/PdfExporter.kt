package at.volkshilfe.nachbesuch.data.export

import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import at.volkshilfe.nachbesuch.domain.export.ExportDocument
import java.io.File
import java.io.FileOutputStream
import kotlin.math.ceil

/** Small monochrome renderer matching the iOS export contract. */
object PdfExporter {
    private const val WIDTH = 595
    private const val HEIGHT = 842
    private const val LEFT = 48f
    private const val RIGHT = 48f
    private const val TOP = 56f
    private const val BOTTOM = 48f
    private const val LINE = 18f

    fun write(document: ExportDocument, file: File) {
        file.parentFile?.mkdirs()
        val pages = pageCount(document)
        val pdf = PdfDocument()
        try {
            for (pageNumber in 1..pages) {
                val page = pdf.startPage(PdfDocument.PageInfo.Builder(WIDTH, HEIGHT, pageNumber).create())
                drawPage(page.canvas, document, pageNumber, pages)
                pdf.finishPage(page)
            }
            FileOutputStream(file).use(pdf::writeTo)
        } finally {
            pdf.close()
        }
    }

    private fun pageCount(document: ExportDocument): Int {
        val lines = 3 + document.houses.sumOf { 2 + it.doors.size + if (it.note != null) 1 else 0 } +
            if (document.summary.counts.isEmpty()) 0 else 2 + document.summary.counts.size
        return ceil(lines / 38.0).toInt().coerceAtLeast(1)
    }

    private fun drawPage(canvas: android.graphics.Canvas, document: ExportDocument, page: Int, pages: Int) {
        val title = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 18f; typeface = android.graphics.Typeface.DEFAULT_BOLD; color = android.graphics.Color.BLACK }
        val body = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 10.5f; color = android.graphics.Color.BLACK }
        val muted = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 9f; color = android.graphics.Color.DKGRAY }
        canvas.drawText(document.title, LEFT, TOP, title)
        var y = TOP + 28f
        val allLines = buildList {
            document.houses.forEach { house ->
                add(house.address to title)
                house.doors.forEach { door -> add("  ${door.label}: ${door.outcome.germanTitle}" to body) }
                house.note?.takeIf(String::isNotBlank)?.let { add("  Notiz: $it" to body) }
                add("" to body)
            }
            if (document.summary.counts.isNotEmpty()) {
                add("Zusammenfassung" to title)
                document.summary.counts.forEach { (outcome, count) -> add("${outcome.germanTitle}: $count" to body) }
            }
        }
        val first = (page - 1) * 38
        val last = minOf(first + 38, allLines.size)
        for (index in first until last) {
            val (line, paint) = allLines[index]
            canvas.drawText(line.take(92), LEFT, y, paint)
            y += if (paint === title) 22f else LINE
        }
        canvas.drawText("Seite $page von $pages", WIDTH - RIGHT - 72f, HEIGHT - BOTTOM, muted)
    }
}
