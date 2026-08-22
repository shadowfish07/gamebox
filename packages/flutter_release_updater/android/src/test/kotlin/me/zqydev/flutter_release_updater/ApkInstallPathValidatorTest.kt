package me.zqydev.flutter_release_updater

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkInstallPathValidatorTest {
    @Test
    fun acceptsOnlyFilesInsideAnApprovedRoot() {
        val parent = Files.createTempDirectory("flutter-updater-test").toFile()
        val root = parent.resolve("files").apply { mkdirs() }

        assertTrue(
            ApkInstallPathValidator.isAllowed(
                root.resolve("updates/app.apk").canonicalFile,
                listOf(root),
            ),
        )
        assertFalse(
            ApkInstallPathValidator.isAllowed(
                parent.resolve("files-escape/app.apk").canonicalFile,
                listOf(root),
            ),
        )
        assertFalse(
            ApkInstallPathValidator.isAllowed(
                parent.resolve("other/app.apk").canonicalFile,
                listOf(root),
            ),
        )
    }
}
