import com.android.build.gradle.BaseExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Деякі плагіни (напр. vosk_flutter_service) досі мають захардкоджений
// застарілий compileSdk у власному build.gradle, нижчий за той, що вимагають
// їхні ж AndroidX-залежності. Примусово вирівнюємо compileSdk усіх
// підпроєктів під той самий, що й у app/build.gradle.kts.
subprojects {
    afterEvaluate {
        extensions.findByType(BaseExtension::class.java)?.let { android ->
            android.compileSdkVersion(37)
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
