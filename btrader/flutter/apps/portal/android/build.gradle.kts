allprojects {
    repositories {
        google()
        mavenCentral()
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

// Plugin AARs (e.g. file_picker's own build.gradle) each pin their own
// compileSdk, independent of the app module's. flutter_plugin_android_lifecycle
// now requires 36+, so force every Android library subproject to compile
// against 36 as well — this only affects what APIs are compiled against, not
// minSdk/targetSdk (device compatibility), which stay as the app sets them.
// pluginManager.withPlugin fires as soon as the plugin applies, so it works
// regardless of evaluation order — afterEvaluate here raced with the :app
// module's own evaluationDependsOn(":app") above and failed.
subprojects {
    pluginManager.withPlugin("com.android.library") {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let {
            it.compileSdkVersion(36)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
