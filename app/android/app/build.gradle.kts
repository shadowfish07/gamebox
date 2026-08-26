import java.util.Properties
import javax.inject.Inject
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.file.FileSystemOperations
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.InputFile
import org.gradle.process.ExecOperations

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
                    "test/**",
                )
                includeEmptyDirs = false
            }
            into(outputDirectory)
        }
    }
}

@CacheableTask
abstract class BuildLanAar : DefaultTask() {
    @get:Inject
    abstract val execOperations: ExecOperations

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val buildScript: RegularFileProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val engineSource: DirectoryProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val goModule: RegularFileProperty

    @get:InputFile
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val goSum: RegularFileProperty

    @get:OutputFile
    abstract val outputAar: RegularFileProperty

    @TaskAction
    fun build() {
        execOperations.exec {
            commandLine(
                "bash",
                buildScript.get().asFile.absolutePath,
                outputAar.get().asFile.absolutePath,
            )
        }
    }
}

val supportedGameboxAbis = setOf("armeabi-v7a", "arm64-v8a", "x86_64")
val selectedGameboxAbi = providers.gradleProperty("gameboxAndroidAbi").orNull
require(selectedGameboxAbi == null || selectedGameboxAbi in supportedGameboxAbis) {
    "Unsupported gameboxAndroidAbi"
}
val gameboxTargetSdk = providers.gradleProperty("GAMEBOX_TARGET_SDK").orNull?.toIntOrNull()
require(gameboxTargetSdk != null && gameboxTargetSdk in 24..flutter.compileSdkVersion) {
    "GAMEBOX_TARGET_SDK must be between minSdk and compileSdk"
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
val stageGameRuntimeAssets = tasks.register<StageGameRuntimeAssets>("stageGameRuntimeAssets") {
    sourceDirectory.set(gameRuntimeSource)
    outputDirectory.set(layout.buildDirectory.dir("generated/gameboxRuntimeAssets"))
}
val buildLanAar = tasks.register<BuildLanAar>("buildLanAar") {
    buildScript.set(rootProject.file("../../tool/build_lan_aar.sh"))
    engineSource.set(rootProject.file("../../server/mobile/lanengine"))
    goModule.set(rootProject.file("../../server/go.mod"))
    goSum.set(rootProject.file("../../server/go.sum"))
    outputAar.set(layout.buildDirectory.file("generated/gameboxLan/gamebox-lan.aar"))
}
tasks.named("preBuild").configure {
    dependsOn(buildLanAar)
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
        targetSdk = gameboxTargetSdk
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    sourceSets.getByName("androidTest").assets.srcDir(
        rootProject.file("../../protocol/fixtures"),
    )

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
                signingConfig = signingConfigs.findByName("release")
                    ?: error("GAMEBOX_DEBUG_ARTIFACT requires android/key.properties")
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
    implementation(files(buildLanAar.flatMap { it.outputAar }))
    implementation("org.godotengine:godot:4.7.0.stable")
    // 1.19.0 requires compileSdk 37; 1.18.0 is the latest API 36-compatible release.
    implementation("androidx.core:core-ktx:1.18.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test.ext:junit:1.3.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test:runner:1.7.0")
    add(standaloneAndroidTestRuntime.name, "androidx.test.uiautomator:uiautomator:2.4.0")
    // Match Flutter embedding's lifecycle ABI when app-target instrumentation
    // loads the helper APK into the target process.
    add(standaloneAndroidTestRuntime.name, "androidx.lifecycle:lifecycle-common:2.7.0")
    add(standaloneAndroidTestRuntime.name, "org.jetbrains.kotlin:kotlin-stdlib:2.4.0")
    // The self-targeting smoke runner cannot borrow runtime classes from the tested APK.
    androidTestImplementation(files(standaloneAndroidTestRuntime))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
