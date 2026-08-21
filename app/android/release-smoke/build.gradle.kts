import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
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

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
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

dependencies {
    implementation("androidx.test.ext:junit:1.2.1")
    implementation("androidx.test:runner:1.6.2")
}
