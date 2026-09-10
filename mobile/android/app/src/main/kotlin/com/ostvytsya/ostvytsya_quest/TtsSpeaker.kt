package com.ostvytsya.ostvytsya_quest

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

/**
 * Резервне озвучення службових повідомлень системним синтезатором Android
 * (без хмари й токенів) — коли локального запису в assets немає. Потребує
 * встановленого українського голосу (Google TTS його має; Samsung TTS —
 * не завжди). Якщо голосу немає або синтезатор не піднявся — onDone(false).
 */
object TtsSpeaker {
    private const val TAG = "TtsSpeaker"

    fun speak(context: Context, text: String, language: String, onDone: (Boolean) -> Unit) {
        var tts: TextToSpeech? = null
        var finished = false
        fun finish(ok: Boolean) {
            if (finished) return
            finished = true
            try {
                tts?.shutdown()
            } catch (_: Throwable) {
            }
            onDone(ok)
        }
        try {
            tts = TextToSpeech(context.applicationContext) { status ->
                if (status != TextToSpeech.SUCCESS) {
                    Log.w(TAG, "Синтезатор не піднявся: $status")
                    finish(false)
                    return@TextToSpeech
                }
                val engine = tts
                if (engine == null) {
                    finish(false)
                    return@TextToSpeech
                }
                val parts = language.split("-", "_")
                val locale = if (parts.size >= 2) Locale(parts[0], parts[1]) else Locale(parts[0])
                val availability = engine.setLanguage(locale)
                if (availability == TextToSpeech.LANG_MISSING_DATA ||
                    availability == TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    Log.w(TAG, "Немає голосу для $language: $availability")
                    finish(false)
                    return@TextToSpeech
                }
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) = finish(true)

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) = finish(false)
                    override fun onError(utteranceId: String?, errorCode: Int) = finish(false)
                })
                val queued = engine.speak(text, TextToSpeech.QUEUE_FLUSH, Bundle(), "restart-notice")
                if (queued != TextToSpeech.SUCCESS) finish(false)
            }
        } catch (err: Throwable) {
            Log.w(TAG, "TTS недоступний", err)
            finish(false)
        }
    }
}
