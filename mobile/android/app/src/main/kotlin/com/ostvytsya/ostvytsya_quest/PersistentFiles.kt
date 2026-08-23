package com.ostvytsya.ostvytsya_quest

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Файли, які мають пережити ВИДАЛЕННЯ застосунку: резервна копія
 * налаштувань і завантажена модель Vosk.
 *
 * Чому не покладаємось на Android Auto Backup (він же мав би рятувати
 * SharedPreferences): відновлення з нього відбувається лише при
 * встановленні через Play Store або під час первинного налаштування
 * пристрою. APK, встановлений збоку (як наші збірки з CI), відновлення НЕ
 * запускає — тому ключі API й зникали при кожному перевстановленні.
 *
 * Тож зберігаємо власноруч у спільній теці `Documents/Оствиця` через
 * MediaStore — так само, як записи квестів. Такі файли система не стирає
 * разом із застосунком.
 */
object PersistentFiles {
    private const val TAG = "PersistentFiles"
    private const val FOLDER = "Оствиця"
    private const val RELATIVE_PATH = "Documents/$FOLDER"

    // VOLUME_EXTERNAL_PRIMARY — константа з Android 10; на старіших беремо
    // класичний том "external". Розгалуження інлайном, щоб його бачив лінт
    // NewApi (на release-збірці він фатальний).
    private fun collection(): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Files.getContentUri("external")
        }

    /** Знайти файл за іменем у нашій теці. */
    private fun findUri(context: Context, name: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            context.contentResolver.query(
                collection(),
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                    "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                arrayOf(name, "%$FOLDER%"),
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                Uri.withAppendedPath(collection(), id.toString())
            }
        } catch (err: Throwable) {
            Log.e(TAG, "Помилка пошуку файлу «$name»", err)
            null
        }
    }

    fun exists(context: Context, name: String): Boolean = findUri(context, name) != null

    /**
     * Створити (або перестворити) файл і віддати його URI. Наявний файл
     * видаляємо: MediaStore інакше додав би поруч копію «name (1)».
     */
    private fun createFresh(context: Context, name: String, mime: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            findUri(context, name)?.let { context.contentResolver.delete(it, null, null) }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            }
            context.contentResolver.insert(collection(), values)
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося створити файл «$name»", err)
            null
        }
    }

    /** Записати невеликий вміст (резервна копія налаштувань). */
    fun writeBytes(context: Context, name: String, bytes: ByteArray, mime: String): Boolean {
        val uri = createFresh(context, name, mime) ?: return false
        return try {
            context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false
            true
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося записати «$name»", err)
            false
        }
    }

    fun readBytes(context: Context, name: String): ByteArray? {
        val uri = findUri(context, name) ?: return null
        return try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося прочитати «$name»", err)
            null
        }
    }

    /**
     * Покласти у сховище великий локальний файл (архів моделі Vosk).
     * Копіюємо потоком і НЕ тягнемо байти через Dart — 50 МБ через
     * канал платформи були б і повільні, і марно з'їли б пам'ять.
     */
    fun importFile(context: Context, name: String, sourcePath: String): Boolean {
        val source = File(sourcePath)
        if (!source.exists()) return false
        val uri = createFresh(context, name, "application/zip") ?: return false
        return try {
            context.contentResolver.openOutputStream(uri)?.use { output ->
                source.inputStream().use { it.copyTo(output) }
            } ?: return false
            true
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося зберегти «$name»", err)
            false
        }
    }

    /** Дістати великий файл зі сховища у локальний файл. */
    fun exportFile(context: Context, name: String, targetPath: String): Boolean {
        val uri = findUri(context, name) ?: return false
        return try {
            val target = File(targetPath)
            target.parentFile?.mkdirs()
            context.contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { input.copyTo(it) }
            } ?: return false
            true
        } catch (err: Throwable) {
            Log.e(TAG, "Не вдалося дістати «$name»", err)
            false
        }
    }

    // ── Шифрування резервної копії налаштувань ───────────────────────────
    //
    // Копія лежить у СПІЛЬНІЙ теці, тож у відкритому вигляді ключі API читав
    // би будь-який файловий менеджер. Шифруємо AES-GCM.
    //
    // ‼️ Чесно про рівень захисту: ключ фіксований і зашитий у застосунок,
    // тобто це захист від випадкового підглядання (файлові менеджери,
    // хмарні синхронізації, чужі очі), а НЕ від того, хто має сам APK і
    // вміє його розібрати. Взяти ключ, прив'язаний до пристрою
    // (ANDROID_ID), тут не можна: якщо він колись зміниться, копія стане
    // недешифрованою, і налаштування зникнуть саме тоді, коли мали б
    // відновитись.

    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    private fun secretKey(context: Context): SecretKeySpec {
        val material = "ostvytsya-quest-backup-v1:${context.packageName}"
        val digest = MessageDigest.getInstance("SHA-256").digest(material.toByteArray())
        return SecretKeySpec(digest, "AES")
    }

    fun encrypt(context: Context, plain: String): ByteArray? = try {
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey(context))
        // IV кладемо на початок файлу — він не таємний, але має бути різним.
        cipher.iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
    } catch (err: Throwable) {
        Log.e(TAG, "Не вдалося зашифрувати резервну копію", err)
        null
    }

    fun decrypt(context: Context, blob: ByteArray): String? = try {
        if (blob.size <= IV_BYTES) null
        else {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(context),
                GCMParameterSpec(TAG_BITS, blob, 0, IV_BYTES)
            )
            String(
                cipher.doFinal(blob, IV_BYTES, blob.size - IV_BYTES),
                Charsets.UTF_8
            )
        }
    } catch (err: Throwable) {
        Log.e(TAG, "Не вдалося розшифрувати резервну копію", err)
        null
    }
}
