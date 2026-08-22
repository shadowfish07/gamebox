package me.zqydev.flutter_release_updater

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import java.io.File
import java.io.IOException
import java.security.MessageDigest

internal enum class ApkInstallResult {
    STARTED,
    PERMISSION_REQUIRED,
}

internal class ApkInstaller(private val activity: Activity) {
    fun install(rawPath: String): ApkInstallResult {
        val apk = try {
            File(rawPath).canonicalFile
        } catch (_: IOException) {
            throw IllegalArgumentException("invalid_path")
        }
        val roots = listOfNotNull(
            activity.filesDir,
            activity.cacheDir,
            activity.getExternalFilesDir(null),
        )
        if (!ApkInstallPathValidator.isAllowed(apk, roots) ||
            !apk.isFile ||
            !apk.name.endsWith(".apk", ignoreCase = true)
        ) {
            throw IllegalArgumentException("invalid_apk")
        }
        if (!ApkPackageValidator.canUpgrade(activity.packageManager, activity.packageName, apk)) {
            throw IllegalArgumentException("incompatible_apk")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            try {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}"),
                    ),
                )
            } catch (_: ActivityNotFoundException) {
                throw IllegalStateException("settings_unavailable")
            } catch (_: SecurityException) {
                throw IllegalStateException("settings_unavailable")
            }
            return ApkInstallResult.PERMISSION_REQUIRED
        }

        val contentUri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.flutter_release_updater.fileprovider",
            apk,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(contentUri, APK_MIME_TYPE)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            throw IllegalStateException("installer_unavailable")
        } catch (_: SecurityException) {
            throw IllegalStateException("installer_unavailable")
        }
        return ApkInstallResult.STARTED
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}

internal object ApkPackageValidator {
    @Suppress("DEPRECATION")
    fun canUpgrade(packageManager: PackageManager, packageName: String, apk: File): Boolean {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apk.path, flags) ?: return false
        val installed = try {
            packageManager.getPackageInfo(packageName, flags)
        } catch (_: PackageManager.NameNotFoundException) {
            return false
        }
        if (candidate.packageName != packageName ||
            PackageInfoCompat.getLongVersionCode(candidate) <=
            PackageInfoCompat.getLongVersionCode(installed)
        ) {
            return false
        }
        return certificateDigests(candidate) == certificateDigests(installed)
    }

    @Suppress("DEPRECATION")
    private fun certificateDigests(packageInfo: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners
        } else {
            packageInfo.signatures
        }
        return signatures.orEmpty().mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString(separator = "") { byte -> "%02x".format(byte) }
        }
    }
}

internal object ApkInstallPathValidator {
    fun isAllowed(candidate: File, roots: List<File>): Boolean {
        val candidatePath = candidate.path
        return roots.any { root ->
            val rootPath = try {
                root.canonicalFile.path
            } catch (_: IOException) {
                return@any false
            }
            candidatePath == rootPath || candidatePath.startsWith("$rootPath${File.separator}")
        }
    }
}
