# Flutter вмикає R8-мінімізацію (isMinifyEnabled) для release-збірок
# автоматично, навіть коли build.gradle.kts цього явно не оголошує
# (FlutterPlugin.kt::shouldShrinkResources). Без цих правил R8 перейменовує
# поле "peer" у com.sun.jna.Pointer, а нативний код JNA (libjnidispatch.so)
# шукає це поле по імені через JNI — звідси
# "UnsatisfiedLinkError: Can't obtain peer field ID for class com.sun.jna.Pointer".
-keep class com.sun.jna.* { *; }
-keepclassmembers class com.sun.jna.* { *; }
-keep class * implements com.sun.jna.* { *; }
-dontwarn com.sun.jna.**

# Vosk (org.vosk.*) теж використовує JNA/JNI для виклику нативної
# бібліотеки розпізнавання — так само не можна обфускувати.
-keep class org.vosk.* { *; }
-dontwarn org.vosk.**
