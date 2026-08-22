package at.volkshilfe.nachbesuch.data.export

import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import at.volkshilfe.nachbesuch.domain.export.ExportDocument
import java.io.File
import java.io.FileOutputStream
import kotlin.math.ceil

/**
 * Monochrome A4 renderer matching the iOS export contract: measured pagination
 * (no fixed lines-per-page estimate that can truncate content), a header block
 * with a restrained summary, clear address hierarchy and "Seite x von y" footers.
 */
object PdfExporter {
    private const val WIDTH = 595
    private const val HEIGHT = 842
    private const val LEFT = 56f
    private const val RIGHT = 56f
    private const val TOP = 56f
    private const val BOTTOM = 48f
    private const val BODY_LINE = 18f
    private const val TITLE_LINE = 24f

    private class Line(val text: String, val isTitle: Boolean) {
        val height: Float get() = if (isTitle) TITLE_LINE else BODY_LINE
    }

    fun write(document: ExportDocument, file: File) {
        file.parentFile?.mkdirs()
        val pages = paginate(document)
        val pdf = PdfDocument()
        try {
            pages.forEachIndexed { index, pageLines ->
                val pageNumber = index + 1
                val page = pdf.startPage(PdfDocument.PageInfo.Builder(WIDTH, HEIGHT, pageNumber).create())
                drawPage(page.canvas, document, pageLines, pageNumber, pages.size)
                pdf.finishPage(page)
            }
            FileOutputStream(file).use(pdf::writeTo)
        } finally {
            pdf.close()
        }
    }

    /** Splits the measured line list so no line is ever dropped or clipped. */
    private fun paginate(document: ExportDocument): List<List<Line>> {
        val lines = buildLines(document)
        if (lines.isEmpty()) return listOf(emptyList())
        val maxBodyWidth = WIDTH - LEFT - RIGHT
        val body = textPaint(size = 10.5f)
        val title = textPaint(size = 13f, bold = true)
        val wrapped = ArrayList<Line>(lines.size + 16)
        lines.forEach { line ->
            val paint = if (line.isTitle) title else body
            measure(line.text, paint)?.takeIf { it > maxBodyWidth }?.let { width ->
                wrap(line, paint, width, maxBodyWidth)
            } ?: wrapped.add(line)
        }
        // Page one carries the header block; continuation pages start lower.
        val pages = ArrayList<List<Line>>()
        var current = ArrayList<Line>()
        val firstPageTop = TOP + (if (document.subtitle.isNotBlank()) 50f else 36f)
        var y = firstPageTop
        wrapped.forEach { line ->
            if (y + line.height > HEIGHT - BOTTOM) {
                pages.add(current)
                current = ArrayList()
                y = TOP + 20f
            }
            current.add(line)
            y += line.height
        }
        if (current.isNotEmpty() || pages.isEmpty()) pages.add(current)
        return pages
    }

    private fun wrap(line: Line, paint: Paint, textWidth: Float, maxWidth: Float): List<Line> {
        val words = line.text.split(' ')
        val result = ArrayList<Line>()
        var currentLine = StringBuilder()
        words.forEach { word ->
            val candidate = if (currentLine.isEmpty()) word else "$currentLine $word"
            val candidateWidth = measure(candidate, paint) ?: 0f
            if (candidateWidth > maxWidth && currentLine.isNotEmpty()) {
                result.add(Line(currentLine.toString(), line.isTitle))
                currentLine = StringBuilder(word)
            } else {
                currentLine = StringBuilder(candidate)
            }
        }
        if (currentLine.isNotEmpty() || result.isEmpty()) {
            result.add(Line(currentLine.toString(), line.isTitle))
        }
        return result
    }

    private fun measure(text: String, paint: Paint): Float? =
        if (text.isBlank()) null else paint.measureText(text)

    private fun buildLines(document: ExportDocument): List<Line> {
        val lines = ArrayList<Line>()
        if (document.houses.isEmpty()) {
            lines += Line("Keine besuchten Häuser in diesem Zeitraum.", isTitle = false)
            return lines
        }
        val doorCount = document.houses.sumOf { it.doors.size }
        val summary = buildList {
            add("${document.houses.size} Häuser")
            add("$doorCount Haushalte")
            document.summary.counts.forEach { (outcome, count) -> add("${outcome.germanTitle}: $count") }
        }
        lines += Line(summary.joinToString("  ·  "), isTitle = false)
        lines += Line("", isTitle = false)

        document.houses.forEach { house ->
            lines += Line(house.address, isTitle = true)
            if (house.totalDoors == 1) {
                val result = house.doors.firstOrNull()?.outcome?.germanTitle ?: "Ohne Status"
                lines += Line("  Ergebnis: $result", isTitle = false)
            } else {
                lines += Line("  ${house.doors.size} von ${house.totalDoors} Türen", isTitle = false)
                house.doors.forEach { door ->
                    lines += Line("    ${door.label}  ·  ${door.resultLabel}", isTitle = false)
                }
            }
            house.note?.takeIf(String::isNotBlank)?.let { lines += Line("  Notiz: $it", isTitle = false) }
        }
        return lines
    }

    private fun drawPage(
        canvas: android.graphics.Canvas,
        document: ExportDocument,
        lines: List<Line>,
        page: Int,
        pages: Int
    ) {
        val title = textPaint(18f, bold = true)
        val muted = textPaint(9f, color = android.graphics.Color.DKGRAY)
        var y: Float
        if (page == 1) {
            val eyebrow = textPaint(8f, bold = true, color = android.graphics.Color.DKGRAY)
            canvas.drawText("NACHBESUCH · EINSATZBERICHT", LEFT, TOP - 20f, eyebrow)
            canvas.drawText(document.title, LEFT, TOP, title)
            var headerY = TOP + 16f
            if (document.subtitle.isNotBlank()) {
                canvas.drawText(document.subtitle, LEFT, headerY, muted)
                headerY += 14f
            }
            canvas.drawText("${document.houses.size} von ${document.totalHouses} Adressen", LEFT, headerY, muted)
            y = headerY + 20f
        } else {
            canvas.drawText("${document.title} (Fortsetzung)", LEFT, TOP, muted)
            y = TOP + 20f
        }
        val body = textPaint(10.5f)
        val heading = textPaint(13f, bold = true)
        val rule = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.LTGRAY
            strokeWidth = 0.6f
        }
        canvas.drawLine(LEFT, y - 8f, WIDTH - RIGHT, y - 8f, rule)
        lines.forEach { line ->
            val paint = if (line.isTitle) heading else body
            canvas.drawText(line.text, LEFT, y, paint)
            y += line.height
        }
        canvas.drawLine(LEFT, HEIGHT - BOTTOM - 14f, WIDTH - RIGHT, HEIGHT - BOTTOM - 14f, rule)
        canvas.drawText("Nachbesuch", LEFT, HEIGHT - BOTTOM, muted)
        val footer = "Seite $page von $pages"
        canvas.drawText(footer, WIDTH - RIGHT - muted.measureText(footer), HEIGHT - BOTTOM, muted)
    }

    private fun textPaint(size: Float, bold: Boolean = false, color: Int = android.graphics.Color.BLACK): Paint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = size
            this.color = color
            typeface = if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
}
