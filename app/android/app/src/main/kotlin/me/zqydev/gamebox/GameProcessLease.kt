package me.zqydev.gamebox

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException

internal class GameProcessLease private constructor(
    private val file: RandomAccessFile,
    private val channel: FileChannel,
    private val lock: FileLock,
) : Closeable {
    override fun close() {
        try {
            lock.release()
        } catch (_: IOException) {
            // The OS releases the lease when the isolated game process exits.
        }
        try {
            channel.close()
        } catch (_: IOException) {
            // Best-effort descriptor cleanup during Activity teardown.
        }
        try {
            file.close()
        } catch (_: IOException) {
            // Best-effort descriptor cleanup during Activity teardown.
        }
    }

    companion object {
        private const val LOCK_FILE_NAME = "active-game.lock"

        fun lockFile(noBackupFilesDir: File): File = noBackupFilesDir.resolve(LOCK_FILE_NAME)

        @Throws(IOException::class)
        fun acquire(lockFile: File): GameProcessLease {
            val parent = lockFile.parentFile
            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                throw IOException("Unable to create game process lease directory.")
            }
            val file = RandomAccessFile(lockFile, "rw")
            val channel = file.channel
            val lock = try {
                channel.tryLock()
            } catch (error: IOException) {
                channel.close()
                file.close()
                throw error
            } catch (error: OverlappingFileLockException) {
                channel.close()
                file.close()
                throw IOException("Game process lease is already held.", error)
            }
            if (lock == null) {
                channel.close()
                file.close()
                throw IOException("Game process lease is already held.")
            }
            return GameProcessLease(file, channel, lock)
        }

        fun isHeld(lockFile: File): Boolean {
            if (!lockFile.exists()) {
                return false
            }
            return try {
                RandomAccessFile(lockFile, "rw").use { file ->
                    file.channel.use { channel ->
                        val lock = channel.tryLock()
                        if (lock == null) {
                            true
                        } else {
                            lock.release()
                            false
                        }
                    }
                }
            } catch (_: OverlappingFileLockException) {
                true
            } catch (_: IOException) {
                // Fail closed: an unreadable lease must never permit a second engine.
                true
            } catch (_: SecurityException) {
                true
            }
        }
    }
}
