package at.volkshilfe.nachbesuch.ui.notice

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Transient user-facing messages, ported from the iOS `AppNoticeCenter`.
 *
 * Before this existed, a failed Room write on Android had nowhere to surface: the
 * repository swallowed it and the user saw a tap that silently did nothing. Every
 * write path that can fail now reports here.
 */
class NoticeCenter(private val scope: CoroutineScope) {

    data class Notice(
        val message: String,
        val isError: Boolean,
        val id: String = UUID.randomUUID().toString()
    )

    private val _current = MutableStateFlow<Notice?>(null)
    val current: StateFlow<Notice?> = _current.asStateFlow()

    /**
     * Notices queue instead of overwriting each other — a backup import that hits
     * several problems used to show only the last one.
     */
    private val queue = ArrayDeque<Notice>()
    private var dismissJob: Job? = null

    fun show(message: String) = enqueue(Notice(message, isError = false))

    fun report(error: Throwable, context: String) =
        enqueue(Notice("$context: ${error.localizedMessage ?: error.javaClass.simpleName}", isError = true))

    fun reportMessage(message: String) = enqueue(Notice(message, isError = true))

    @Synchronized
    private fun enqueue(notice: Notice) {
        if (_current.value == null) present(notice) else queue.addLast(notice)
    }

    private fun present(notice: Notice) {
        dismissJob?.cancel()
        _current.value = notice
        // Errors stay until dismissed; informational notices time out.
        if (notice.isError) return
        dismissJob = scope.launch {
            delay(NOTICE_TIMEOUT_MS)
            dismiss()
        }
    }

    @Synchronized
    fun dismiss() {
        dismissJob?.cancel()
        dismissJob = null
        _current.value = null
        queue.removeFirstOrNull()?.let(::present)
    }

    private companion object {
        const val NOTICE_TIMEOUT_MS = 5_000L
    }
}
