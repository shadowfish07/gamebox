import java.util.Properties

plugins {
    id("com.android.application")
}

val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) {
        signingPropertiesFile.inputStream().use(::load)
    }
}

android {
    namespace = "me.zqydev.gamebox.release_smoke"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "me.zqydev.gamebox.release_smoke"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1"
    }

    signingConfigs {
        if (signingPropertiesFile.isFile) {
            create("release") {
                storeFile = rootProject.file(
                    "app/${signingProperties.getProperty("storeFile")}",
                )
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
    }

    lint {
        checkReleaseBuilds = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.test.ext:junit:1.3.0")
    implementation("androidx.test:runner:1.7.0")
}
