plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ostvytsya.ostvytsya_quest"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
