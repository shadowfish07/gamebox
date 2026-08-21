import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val supportedGameboxAbis = setOf("armeabi-v7a", "arm64-v8a", "x86_64")
val selectedGameboxAbi = providers.gradleProperty("gameboxAndroidAbi").orNull
require(selectedGameboxAbi == null || selectedGameboxAbi in supportedGameboxAbis) {
    "Unsupported gameboxAndroidAbi"
}
val standaloneAndroidTestRuntime by configurations.creating
val signingPropertiesFile = rootProject.file("key.properties")
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) {
        signingPropertiesFile.inputStream().use(::load)
    }
}
val requireReleaseSigning = providers.environmentVariable("GAMEBOX_REQUIRE_RELEASE_SIGNING")
    .orNull == "true"
require(!requireReleaseSigning || signingPropertiesFile.isFile) {
    "GAMEBOX_REQUIRE_RELEASE_SIGNING requires android/key.properties"
}
val gameRuntimeSource = rootProject.file("../../game_runtime")
val stagedGameRuntimeAssets = layout.buildDirectory.dir("generated/gameboxRuntimeAssets")
val stageGameRuntimeAssets by tasks.registering(Sync::class) {
    from(gameRuntimeSource) {
        include(
            "project.godot",
            "main.gd",
            "main.gd.uid",
            "main.tscn",
            "core/**",
            "games/**",
            ".godot/imported/**",
        )
        exclude(
            ".gdignore",
            "**/.gdignore",
            ".godot/editor/**",
            ".godot/uid_cache.bin",
            ".godot/global_script_class_cache.cfg",
            ".godot/filesystem_cache*",
            ".godot/*metadata*",
            "test/**",
        )
        includeEmptyDirs = false
    }
    into(stagedGameRuntimeAssets)
}

android {
    namespace = "me.zqydev.gamebox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "me.zqydev.gamebox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (signingPropertiesFile.isFile) {
            create("release") {
                storeFile = file(signingProperties.getProperty("storeFile"))
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
        }
    }

    sourceSets["main"].assets.srcDir(stagedGameRuntimeAssets)

    androidResources {
        // Android's default excludes hidden directories used by Godot project data.
        ignoreAssetsPattern = "!.svn:!.git:!.gitignore:!.ds_store:!*.scc:<dir>_*:!CVS:!thumbs.db:!picasa.ini:!*~"
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
            // The runtime is GLES-only; do not ship Godot's unused Vulkan validation layer.
            excludes += "lib/**/libVkLayer_khronos_validation.so"
            selectedGameboxAbi?.let { selectedAbi ->
                excludes += supportedGameboxAbis
                    .filterNot { it == selectedAbi }
                    .map { abi -> "lib/$abi/**" }
            }
        }
    }
}

tasks.named("preBuild").configure {
    dependsOn(stageGameRuntimeAssets)
}

flutter {
    source = "../.."
}

dependencies {
    implementation("org.godotengine:godot:4.7.0.stable")
    implementation("androidx.core:core-ktx:1.15.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test.ext:junit:1.2.1")
    add(standaloneAndroidTestRuntime.name, "androidx.test:runner:1.6.2")
    add(standaloneAndroidTestRuntime.name, "androidx.test.uiautomator:uiautomator:2.3.0")
    add(standaloneAndroidTestRuntime.name, "org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
    // The self-targeting smoke runner cannot borrow runtime classes from the tested APK.
    androidTestImplementation(files(standaloneAndroidTestRuntime))
    testImplementation("junit:junit:4.13.2")
}
