plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.btrader.btrader_trader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // White-label: app id + home-screen label come from Gradle properties so
        // each tenant gets a distinct, side-by-side-installable app without
        // editing this file. Defaults = Example. Pass at build time:
        //   -Papp.id=com.broker.trader -Papp.label=Broker
        // (build-trader-apk.sh sets these per tenant.)
        applicationId = (project.findProperty("app.id") as String?) ?: "io.btrader.btrader_trader"
        manifestPlaceholders["appLabel"] = (project.findProperty("app.label") as String?) ?: "Example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 23 = Android 6.0: required by local_auth (BiometricPrompt) and
        // flutter_secure_storage's EncryptedSharedPreferences.
        minSdk = maxOf(23, flutter.minSdkVersion)
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
