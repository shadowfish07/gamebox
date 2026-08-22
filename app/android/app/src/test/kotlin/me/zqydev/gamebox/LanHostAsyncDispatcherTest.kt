package me.zqydev.gamebox

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LanHostAsyncDispatcherTest {
    @Test
    fun `started command waits for foreground-ready service runs off caller and posts one result`() {
        val waitEntered = CountDownLatch(1)
        val foregroundReady = LanHostServiceReadyBarrier(waitEntered::countDown)
        val commands = CountingCommands()
        val worker = CapturingExecutor()
        val main = CapturingExecutor()
        var starts = 0
        val replies = mutableListOf<LanChannelReply>()
        val dispatcher = LanHostAsyncDispatcher(
            foregroundReady,
            { starts++ },
            { true },
            worker,
            main,
            timeoutMillis = 5_000,
        )

        dispatcher.dispatch("createRoom", mapOf("nickname" to "Host")) { replies.add(it) }
        assertEquals(1, starts)
        assertEquals(0, commands.creates)
        assertTrue(replies.isEmpty())

        val workerThread = Thread(worker.take())
        workerThread.start()
        assertTrue(waitEntered.await(2, TimeUnit.SECONDS))
        assertEquals(0, commands.creates)
        foregroundReady.ready(commands)
        workerThread.join(2_000)

        assertEquals(1, commands.creates)
        assertTrue(replies.isEmpty())
        main.take().run()
        assertEquals(1, replies.size)
        assertTrue(replies.single() is LanChannelReply.Success)
        assertTrue(main.isEmpty())
    }

    @Test
    fun `destroyed service releases waiter with one credential-free unavailable response and no command`() {
        val waitEntered = CountDownLatch(1)
        val foregroundReady = LanHostServiceReadyBarrier(waitEntered::countDown)
        val commands = CountingCommands()
        val worker = CapturingExecutor()
        val main = CapturingExecutor()
        val replies = mutableListOf<LanChannelReply>()
        LanHostAsyncDispatcher(foregroundReady, {}, { true }, worker, main, 5_000)
            .dispatch("createRoom", mapOf("nickname" to "Host")) { replies.add(it) }

        val workerThread = Thread(worker.take())
        workerThread.start()
        assertTrue(waitEntered.await(2, TimeUnit.SECONDS))
        foregroundReady.destroyed(commands)
        workerThread.join(2_000)
        main.take().run()

        assertEquals(0, commands.creates)
        val failure = replies.single() as LanChannelReply.Failure
        assertEquals("service_unavailable", failure.code)
        assertEquals(null, failure.details)
    }

    @Test
    fun `invalid call never starts waits or executes`() {
        val barrier = LanHostServiceReadyBarrier()
        val worker = CapturingExecutor()
        val main = CapturingExecutor()
        var starts = 0
        val replies = mutableListOf<LanChannelReply>()

        LanHostAsyncDispatcher(barrier, { starts++ }, { false }, worker, main, 5_000)
            .dispatch("createRoom", mapOf("nickname" to " ")) { replies.add(it) }

        assertEquals(0, starts)
        assertTrue(worker.isEmpty())
        main.take().run()
        assertEquals("invalid_arguments", (replies.single() as LanChannelReply.Failure).code)
    }

    @Test
    fun `fresh install status returns exact empty without starting or waiting`() {
        val waitEntered = CountDownLatch(1)
        val barrier = LanHostServiceReadyBarrier(waitEntered::countDown)
        val worker = CapturingExecutor()
        val main = CapturingExecutor()
        var starts = 0
        val replies = mutableListOf<LanChannelReply>()

        LanHostAsyncDispatcher(barrier, { starts++ }, { false }, worker, main, 5_000)
            .dispatch("getStatus", null) { replies.add(it) }
        worker.take().run()
        main.take().run()

        assertEquals(0, starts)
        assertEquals(1L, waitEntered.count)
        assertEquals(emptyStatus(), (replies.single() as LanChannelReply.Success).value)
    }

    @Test
    fun `persisted room status waits for authoritative foreground restore instead of faking empty`() {
        val waitEntered = CountDownLatch(1)
        val barrier = LanHostServiceReadyBarrier(waitEntered::countDown)
        val worker = CapturingExecutor()
        val main = CapturingExecutor()
        val replies = mutableListOf<LanChannelReply>()
        val commands = CountingCommands()
        LanHostAsyncDispatcher(barrier, {}, { true }, worker, main, 5_000)
            .dispatch("getStatus", null) { replies.add(it) }

        val workerThread = Thread(worker.take())
        workerThread.start()
        assertTrue(waitEntered.await(2, TimeUnit.SECONDS))
        assertTrue(replies.isEmpty())
        barrier.ready(commands)
        workerThread.join(2_000)
        main.take().run()

        assertEquals(status(), (replies.single() as LanChannelReply.Success).value)
    }

    private class CapturingExecutor : Executor {
        private val tasks = ArrayDeque<Runnable>()

        override fun execute(command: Runnable) {
            tasks.addLast(command)
        }

        fun take(): Runnable = tasks.removeFirst()

        fun isEmpty(): Boolean = tasks.isEmpty()
    }

    private class CountingCommands : LanHostCommands {
        var creates = 0

        override fun getStatus() = status()
        override fun createRoom(nickname: String) = LinkedHashMap(status()).apply {
            put("roomKey", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            put("joinExpiresAt", 60_000L)
            creates++
        }
        override fun issueHostLaunch() = status()
        override fun refreshEndpoint() = status()
        override fun closeRoom(mode: String) = status()
        override fun stopCompletedRoom(allowMissingGuestAck: Boolean) = status()

        private fun status() = linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "state" to "waiting",
            "roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "port" to 50000,
            "gameRevision" to 0L,
            "endpointChanged" to false,
            "endpoint" to "192.168.1.4:50000",
        )
    }

    private companion object {
        fun status() = linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "state" to "waiting",
            "roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "port" to 50000,
            "gameRevision" to 0L,
            "endpointChanged" to false,
            "endpoint" to "192.168.1.4:50000",
        )

        fun emptyStatus() = linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "state" to "empty",
            "roomId" to null,
            "port" to 0,
            "gameRevision" to 0L,
            "endpointChanged" to false,
            "endpoint" to null,
        )
    }
}
