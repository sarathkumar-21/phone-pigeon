package dev.phonepigeon.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import dev.phonepigeon.proto.InputKind
import dev.phonepigeon.proto.RemoteInput
import kotlin.math.max
import kotlin.math.min

/**
 * Lets the Mac tap, swipe and type on this phone while screen mirroring is running.
 *
 * This is an Android Accessibility Service, so Android makes the owner enable it by hand in Settings and warns
 * about it. PhonePigeon only acts on input when ALL of these hold: this service is enabled, "Remote control from Mac" is
 * switched on in PhonePigeon, and a screen-mirroring session the owner approved is currently active. It never reads
 * screen content, and it ignores window events.
 */
class RemoteControlService : AccessibilityService() {
    companion object {
        @Volatile var instance: RemoteControlService? = null
            private set
    }

    override fun onServiceConnected() { instance = this }
    override fun onUnbind(intent: android.content.Intent?): Boolean { instance = null; return super.onUnbind(intent) }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    fun perform(input: RemoteInput) {
        val bounds = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        val w = bounds.width().toFloat()
        val h = bounds.height().toFloat()
        fun px(f: Float) = (f.coerceIn(0f, 1f) * w)
        fun py(f: Float) = (f.coerceIn(0f, 1f) * h)
        when (input.kind) {
            InputKind.INPUT_TAP -> gesture(px(input.x), py(input.y), px(input.x), py(input.y), 60)
            InputKind.INPUT_LONG_PRESS -> gesture(px(input.x), py(input.y), px(input.x), py(input.y), 700)
            InputKind.INPUT_SWIPE -> gesture(px(input.x), py(input.y), px(input.x2), py(input.y2), input.durationMs.coerceIn(80, 1500))
            InputKind.INPUT_BACK -> performGlobalAction(GLOBAL_ACTION_BACK)
            InputKind.INPUT_HOME -> performGlobalAction(GLOBAL_ACTION_HOME)
            InputKind.INPUT_RECENTS -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            InputKind.INPUT_ENTER -> focusedInput()?.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            InputKind.INPUT_TEXT -> typeText(input.text.take(500))
        }
    }

    private fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, duration: Int) {
        val path = Path().apply { moveTo(x1, y1); if (x1 != x2 || y1 != y2) lineTo(x2, y2) else lineTo(x1 + 0.1f, y1 + 0.1f) }
        dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, max(1, duration).toLong())).build(), null, null)
    }

    private fun focusedInput(): AccessibilityNodeInfo? = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    /** Appends typed characters to the focused text field; "\u0008" deletes the last character. */
    private fun typeText(typed: String) {
        val node = focusedInput() ?: return
        var current = node.text?.toString().orEmpty()
        if (node.isShowingHintText) current = ""
        for (c in typed) current = if (c == '\u0008') current.dropLast(1) else current + c
        val args = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current) }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }
}
