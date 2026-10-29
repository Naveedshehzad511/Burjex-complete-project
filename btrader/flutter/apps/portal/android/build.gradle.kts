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
// Plugin AARs (e.g. file_picker's own build.gradle) each pin their own
// compileSdk, independent of the app module's. flutter_plugin_android_lifecycle
// now requires 36+, so force every Android library subproject to compile
// against 36 as well — this only affects what APIs are compiled against, not
// minSdk/targetSdk (device compatibility), which stay as the app sets them.
// The override runs after each plugin's own build.gradle (pluginManager.withPlugin
// fired before it, so the plugin's "compileSdk 34" line overwrote the 36 again).
// It is registered before evaluationDependsOn(":app") below, which evaluates
// projects early; one already evaluated gets the override straight away.
subprojects {
    val forceCompileSdk: (Project) -> Unit = { p ->
        if (p.plugins.hasPlugin("com.android.library")) {
            p.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.compileSdkVersion(36)
        }
    }
    if (state.executed) forceCompileSdk(this) else afterEvaluate { forceCompileSdk(this) }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
