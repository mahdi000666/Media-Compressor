pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// Native plugins must use the app's Android and Kotlin build plugin versions.
gradle.beforeProject {
    if (name in listOf("media_kit_libs_android_video", "media_kit_video", "package_info_plus", "wakelock_plus")) {
        buildscript.configurations.configureEach {
            resolutionStrategy.eachDependency {
                if (requested.group == "com.android.tools.build" && requested.name == "gradle") {
                    useVersion("9.1.0")
                }
                if (requested.group == "org.jetbrains.kotlin" && requested.name.startsWith("kotlin-gradle-plugin")) {
                    useVersion("2.4.0")
                }
            }
        }
    }
}
