package com.ostvytsya.ostvytsya_quest

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Log
import java.io.File

/**
 * Сховище записів сесій у СПІЛЬНІЙ медіатеці пристрою (MediaStore →
 * `Music/Оствиця`), а не в теці застосунку.
 *
 * Навіщо: тека застосунку (`Android/data/<pkg>/files`) СТИРАЄТЬСЯ системою
 * разом із застосунком при видаленні — записи квестів зникали при кожному
 * оновленні через перевстановлення APK. Ключі API так не зникають, бо
 * flutter_secure_storage лягає в SharedPreferences, які підхоплює Android
 * Auto Backup; для аудіо той механізм не годиться (він не бекапить зовнішнє
 * сховище й має ліміт ~25 МБ).
 *
 * Файли в спільній медіатеці переживають видалення застосунку, видні у
 * будь-якому файловому менеджері та музичному програвачі, і не потребують
 * жодних дозволів на ЗАПИС (scoped storage: застосунок завжди може
 * створювати власні записи в MediaStore). Дозвіл потрібен лише щоб ПРОЧИТАТИ
 * файли, створені ПОПЕРЕДНІМ встановленням застосунку — саме заради історії
 * після перевстановлення (READ_MEDIA_AUDIO на Android 13+,
 * READ_EXTERNAL_STORAGE на 10..12).
 *
 * На Android 9 і старіших (API < 29) MediaStore ще не має RELATIVE_PATH /
 * IS_PENDING, тож там лишається стара поведінка — тека застосунку.
 */
object SessionRecordingsStore {
    private const val TAG = "SessionRecordings"

    /** Підтека всередині спільної теки «Музика». */
    const val FOLDER = "Оствиця"

    private const val RELATIVE_PATH = "Music/$FOLDER"
    private const val MIME = "audio/mp4"

    private fun collection(): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

    /**
     * Створити новий запис у медіатеці й відкрити його на запис.
     * Позначається IS_PENDING=1, щоб інші застосунки не бачили недописаний
     * файл; знімається у [markComplete].
     *
     * Перевірка версії — навмисно ІНЛАЙНОМ у кожній функції, а не через
     * спільний хелпер: так її бачить лінт Android (NewApi), який на
     * release-збірці фатальний і не вміє «дивитись» усередину чужої функції.
     */
    fun create(context: Context, displayName: String): Pair<Uri, ParcelFileDescriptor>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, MIME)
                put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = context.contentResolver.insert(collection(), values) ?: return null
            val pfd = context.contentResolver.openFileDescriptor(uri, "w")
            if (pfd == null) {
                context.contentResolver.delete(uri, null, null)
                return null
            }
            uri to pfd
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося створити запис у медіатеці", err)
            null
        }
    }

    /**
     * Зняти IS_PENDING — після цього файл видно всім застосункам.
     *
     * Назва навмисно не `finalize`: так зветься метод java.lang.Object, і
     * однойменна функція тут лише плутала б.
     */
    fun markComplete(context: Context, uri: Uri) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            context.contentResolver.update(uri, values, null, null)
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося завершити запис у медіатеці", err)
        }
    }

    /** Прибрати порожній запис, який так і не вдалося наповнити. */
    fun discard(context: Context, uri: Uri) {
        try {
            context.contentResolver.delete(uri, null, null)
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося прибрати незавершений запис", err)
        }
    }

    /**
     * Перелік усіх записів квестів у медіатеці — включно зі створеними
     * ПОПЕРЕДНІМИ встановленнями застосунку (саме заради цього все й
     * затіяно). Якщо немає дозволу на читання чужих медіафайлів, система
     * поверне лише власні — список просто буде коротшим, без помилки.
     */
    fun list(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val args = arrayOf("%$FOLDER%")
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
                            // MediaStore тримає DATE_MODIFIED у СЕКУНДАХ епохи,
                            // а Dart чекає мілісекунди.
                            "modified" to cursor.getLong(dateCol) * 1000L
                        )
                    )
                }
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося перелічити записи в медіатеці", err)
        }
        return out
    }

    /**
     * Скопіювати запис у кеш застосунку й повернути звичайний шлях до файлу.
     * Потрібно для «поділитись»: share_plus приймає файл, а не content://.
     */
    fun copyToCache(context: Context, uri: Uri, displayName: String): String? {
        return try {
            val dir = File(context.cacheDir, "share")
            if (!dir.exists()) dir.mkdirs()
            val target = File(dir, displayName)
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося скопіювати запис у кеш", err)
            null
        }
    }
}
