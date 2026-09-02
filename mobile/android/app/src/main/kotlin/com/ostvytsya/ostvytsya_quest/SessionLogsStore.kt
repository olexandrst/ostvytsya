package com.ostvytsya.ostvytsya_quest

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log

/**
 * Текстові журнали сесій квесту у спільній теці `Documents/Оствиця/logs`
 * (MediaStore.Files) — з тими самими іменами, що й аудіозаписи в
 * `Music/Оствиця`, лише з розширенням .txt (`quest_<час>.m4a` ↔
 * `quest_<час>.txt`).
 *
 * Чому не поруч із аудіо: у `Music/` MediaStore пускає лише аудіофайли, а
 * для довільних типів дозволені тільки `Documents/` і `Download/`.
 *
 * Той самий принцип, що й у SessionRecordingsStore/PersistentFiles: файли
 * переживають видалення застосунку. На Android 9 і старіших (немає
 * RELATIVE_PATH) Dart-бік відкочується на теку застосунку.
 */
object SessionLogsStore {
    private const val TAG = "SessionLogs"
    private const val FOLDER = "Оствиця"
    private const val SUBFOLDER = "logs"
    private const val RELATIVE_PATH = "Documents/$FOLDER/$SUBFOLDER"
    private const val MIME = "text/plain"

    // Розгалуження інлайном, щоб його бачив лінт NewApi (на release-збірці
    // він фатальний).
    private fun collection(): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Files.getContentUri("external")
        }

    /** Створити порожній журнал; null — MediaStore недоступний, пиши в теку застосунку. */
    fun create(context: Context, displayName: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, MIME)
                put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            }
            context.contentResolver.insert(collection(), values)
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося створити журнал «$displayName»", err)
            null
        }
    }

    /**
     * Дописати текст у кінець журналу. Відкриваємо/закриваємо потік на
     * кожен рядок: рядків небагато, зате на диску завжди актуальний файл —
     * навіть якщо застосунок раптом упаде посеред квесту.
     */
    fun append(context: Context, uri: Uri, text: String): Boolean {
        return try {
            val stream = context.contentResolver.openOutputStream(uri, "wa") ?: return false
            stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
            true
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося дописати журнал", err)
            false
        }
    }

    /** Перелік журналів — найновіші перші. */
    fun list(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
            "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?"
        val args = arrayOf("%$FOLDER/$SUBFOLDER%", "%.txt")
        try {
            context.contentResolver.query(
                collection(),
                projection,
                selection,
                args,
                "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
            )?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    out.add(
                        mapOf(
                            "uri" to ContentUris.withAppendedId(collection(), id).toString(),
                            "name" to cursor.getString(nameCol),
                            "size" to cursor.getLong(sizeCol),
                            // DATE_MODIFIED у MediaStore — секунди епохи, Dart чекає мс.
                            "modified" to cursor.getLong(dateCol) * 1000L
                        )
                    )
                }
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося перелічити журнали", err)
        }
        return out
    }

    fun read(context: Context, uri: Uri): String? = try {
        context.contentResolver.openInputStream(uri)?.use {
            it.bufferedReader(Charsets.UTF_8).readText()
        }
    } catch (err: Throwable) {
        Log.e(TAG, "Не вдалося прочитати журнал", err)
        null
    }
}
