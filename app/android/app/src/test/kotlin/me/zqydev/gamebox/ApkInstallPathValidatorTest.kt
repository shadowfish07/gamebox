package me.zqydev.gamebox

import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ApkInstallPathValidatorTest {
    @Test
    fun acceptsOnlyFilesInsideAnApprovedRoot() {
        val parent = Files.createTempDirectory("gamebox-installer-test").toFile()
        val root = parent.resolve("files").apply { mkdirs() }

        assertTrue(
            ApkInstallPathValidator.isAllowed(
                root.resolve("updates/gamebox.apk").canonicalFile,
                listOf(root),
            ),
        )
        assertFalse(
            ApkInstallPathValidator.isAllowed(
                parent.resolve("files-escape/gamebox.apk").canonicalFile,
                listOf(root),
            ),
        )
        assertFalse(
            ApkInstallPathValidator.isAllowed(
                parent.resolve("other/gamebox.apk").canonicalFile,
                listOf(root),
            ),
        )
    }
}
