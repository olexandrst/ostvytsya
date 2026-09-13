import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Підпис APK ───────────────────────────────────────────────────────────────
// Щоб APK можна було СТАВИТИ ПОВЕРХ наявного (оновлення без видалення), кожна
// збірка мусить бути підписана ТИМ САМИМ ключем: при розбіжності підпису
// Android відмовляє в оновленні (INSTALL_FAILED_UPDATE_INCOMPATIBLE), і
// застосунок доводиться спершу видаляти — разом із ключами й налаштуваннями.
// Раніше release підписувався debug-ключем, а Gradle генерує його на кожній
// машині (і на КОЖНОМУ раннері CI) заново — тож кожна збірка мала новий підпис.
//
// Джерело ключа, за пріоритетом:
//   1. android/key.properties (storeFile, storePassword, keyAlias, keyPassword)
//      або ті самі значення у змінних середовища ANDROID_KEYSTORE_FILE,
//      ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD —
//      так у CI можна підкласти власний приватний ключ із секретів репозиторію;
//   2. android/ostvytsya-shared.jks — спільний ключ парку, що лежить у
//      репозиторії з паролем «android» (як у типового debug-ключа Android).
//      Це НЕ таємниця, а лише гарантія стабільного підпису для APK, які
//      ставлять вручну, а не через Google Play. Хочеш справжній приватний
//      ключ — додай його через п.1, нічого іншого міняти не треба.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun signingSetting(property: String, env: String, fallback: String): String =
    (keystoreProperties.getProperty(property) ?: System.getenv(env))
        ?.takeIf { it.isNotBlank() } ?: fallback

android {
    namespace = "com.ostvytsya.ostvytsya_quest"
    // flutter_secure_storage й permission_handler_android вимагають compileSdk
    // 37 — вище за типове flutter.compileSdkVersion цієї версії Flutter.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.ostvytsya.ostvytsya_quest"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Номер версії (versionCode) мусить лише зростати, інакше Android
        // вважає нову збірку «відкатом» і не ставить її поверх. У CI його
        // задає номер запуску збірки: flutter build apk --build-number=…
        // (див. .github/workflows/mobile-build.yml); локально береться з
        // pubspec.yaml.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("shared") {
            storeFile = rootProject.file(
                signingSetting("storeFile", "ANDROID_KEYSTORE_FILE", "ostvytsya-shared.jks")
            )
            storePassword = signingSetting("storePassword", "ANDROID_KEYSTORE_PASSWORD", "android")
            keyAlias = signingSetting("keyAlias", "ANDROID_KEY_ALIAS", "ostvytsya")
            keyPassword = signingSetting("keyPassword", "ANDROID_KEY_PASSWORD", "android")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("shared")
        }
        // Debug — тим самим ключем: так збірка з `flutter run` і APK із CI
        // стають взаємозамінними (ставляться одна поверх одної без видалення).
        debug {
            signingConfig = signingConfigs.getByName("shared")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // NotificationCompat для сповіщення сервісу QuestForegroundService.
    implementation("androidx.core:core-ktx:1.13.1")
}

// vosk_flutter_service жорстко тягне net.java.dev.jna:jna:5.15.0@aar, а
// сам vosk-android (com.alphacephei:vosk-android:0.3.75) вимагає
// jna:5.18.1@aar. Розсинхрон між Java-класами JNA й native libjnidispatch.so
// з різних версій AAR призводить до краху "Can't obtain peer field ID for
// class com.sun.jna.Pointer" у Native.initIDs(). Примусово вирівнюємо
// на одну версію, якої фактично вимагає vosk-android.
configurations.all {
    // Без "@aar" — force() очікує лише group:name:version, тип артефакту
    // (aar) і так береться з того, як jna запитує кожен споживач.
    resolutionStrategy.force("net.java.dev.jna:jna:5.18.1")
}
