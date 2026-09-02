import java.util.Properties
import javax.inject.Inject
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

abstract class StageGameRuntimeAssets : DefaultTask() {
    @get:Inject
    abstract val fileSystemOperations: FileSystemOperations

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sourceDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun stage() {
        fileSystemOperations.sync {
            from(sourceDirectory) {
                include(
                    "project.godot",
                    "main.gd",
                    "main.gd.uid",
                    "main.tscn",
                    "core/**",
                    "design_system/**",
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
                    ".godot/imported/**/*.md5",
                    "test/**",
                )
                includeEmptyDirs = false
            }
            into(outputDirectory)
        }
    }
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
val debugArtifact = providers.environmentVariable("GAMEBOX_DEBUG_ARTIFACT")
    .orNull == "true"
require(!requireReleaseSigning || signingPropertiesFile.isFile) {
    "GAMEBOX_REQUIRE_RELEASE_SIGNING requires android/key.properties"
}
val gameRuntimeSource = rootProject.file("../../game_runtime")
val godotExecutable = providers.environmentVariable("GODOT_BIN").orElse(
    providers.provider {
        val macOsBundleExecutable = file("/Applications/Godot.app/Contents/MacOS/Godot")
        if (macOsBundleExecutable.isFile) macOsBundleExecutable.absolutePath else "godot"
    },
)
val importGameRuntimeAssets = tasks.register<Exec>("importGameRuntimeAssets") {
    description = "Imports generated Godot resources required by the embedded runtime"
    workingDir(gameRuntimeSource)
    inputs.files(
        fileTree(gameRuntimeSource) {
            include(
                "project.godot",
                "main.gd",
                "main.gd.uid",
                "main.tscn",
                "core/**",
                "design_system/**",
                "games/**",
            )
            exclude(".godot/**", "test/**")
        },
    ).withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.property("godotExecutable", godotExecutable)
    outputs.dir(gameRuntimeSource.resolve(".godot/imported"))
    doFirst {
        commandLine(
            godotExecutable.get(),
            "--headless",
            "--path",
            gameRuntimeSource.absolutePath,
            "--import",
        )
    }
}
val stageGameRuntimeAssets = tasks.register<StageGameRuntimeAssets>("stageGameRuntimeAssets") {
    dependsOn(importGameRuntimeAssets)
    sourceDirectory.set(gameRuntimeSource)
    outputDirectory.set(layout.buildDirectory.dir("generated/gameboxRuntimeAssets"))
}

android {
    namespace = "me.zqydev.gamebox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "me.zqydev.gamebox"
        // CI-published debug artifacts override this to a distinct launcher label.
        manifestPlaceholders["appLabel"] = "gamebox"
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
        debug {
            if (debugArtifact) {
                // CI-published debug APKs get a distinct application id so they
                // coexist with a release install on the same device, plus a
                // distinguishable launcher label. Local debug builds are
                // unaffected.
                applicationIdSuffix = ".debug"
                manifestPlaceholders["appLabel"] = "gamebox debug"
                signingConfig = if (requireReleaseSigning) {
                    signingConfigs.findByName("release")
                        ?: error("GAMEBOX_REQUIRE_RELEASE_SIGNING requires android/key.properties")
                } else {
                    // Untrusted branch and pull-request artifacts use the
                    // ephemeral Android debug key and never receive stable
                    // signing material.
                    signingConfigs.getByName("debug")
                }
            }
        }
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

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

androidComponents.onVariants { variant ->
    variant.sources.assets?.addGeneratedSourceDirectory(
        stageGameRuntimeAssets,
        StageGameRuntimeAssets::outputDirectory,
    )
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
    implementation("org.godotengine:godot:4.7.0.stable")
    // 1.19.0 requires compileSdk 37; 1.18.0 is the latest API 36-compatible release.
    implementation("androidx.core:core-ktx:1.18.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test.ext:junit:1.3.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test:runner:1.7.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test.uiautomator:uiautomator:2.4.0")
    add(standaloneAndroidTestRuntime.name, "org.jetbrains.kotlin:kotlin-stdlib:2.4.0")
    // The self-targeting smoke runner cannot borrow runtime classes from the tested APK.
    androidTestImplementation(files(standaloneAndroidTestRuntime))
    testImplementation("junit:junit:4.13.2")
}
