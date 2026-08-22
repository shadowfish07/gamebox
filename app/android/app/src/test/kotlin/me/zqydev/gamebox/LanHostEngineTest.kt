package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LanHostEngineTest {
    @Test
    fun `host engine exposes the strict service boundary`() {
        val engineClass = runCatching {
            Class.forName("me.zqydev.gamebox.LanHostEngine")
        }.getOrNull()

        assertNotNull("LanHostEngine interface is missing", engineClass)
        assertTrue(
            engineClass!!.declaredMethods.map { it.name }.toSet().containsAll(
                setOf("createRoom", "restore", "issueHostLaunch", "status", "stop", "deleteActiveRoom"),
            ),
        )
    }

    @Test
    fun `create persists generated authority before invoking Go`() {
        val order = mutableListOf<String>()
        val persistence = FakePersistence(order)
        val engine = FakeEngine(order)
        val secrets = fixtureSecrets()
        val coordinator = LanHostCoordinator(
            engine = engine,
            persistence = persistence,
            generateSecrets = { secrets },
            nowMillis = { 1_000L },
        )

        val outcome = coordinator.createRoomWithAuthority("Host \"One\"")

        assertEquals("created", outcome.statusJson)
        assertEquals(secrets, outcome.secrets)
        assertEquals(601_000L, outcome.joinExpiresAt)
        assertEquals(listOf("persist", "create"), order)
        assertEquals(secrets, persistence.current)
        assertTrue(engine.createRequest.contains("\"joinExpiresAt\":601000"))
        assertTrue(engine.createRequest.contains("\"hostNickname\":\"Host \\\"One\\\"\""))
        assertTrue(engine.createRequest.contains(secrets.roomKey))
        assertFalse(coordinator.toString().contains(secrets.roomKey))
    }

    @Test
    fun `definitive precommit rejection removes only generated bundle while ambiguity retains it`() {
        val secrets = fixtureSecrets()
        val definitiveStore = FakePersistence()
        val definitiveEngine = FakeEngine().apply { createError = LanEngineException("invalid_configuration") }
        val definitive = LanHostCoordinator(definitiveEngine, definitiveStore, { secrets }, { 1_000L })

        assertThrows(LanEngineException::class.java) { definitive.createRoom("Host") }
        assertEquals(1, definitiveStore.deleteMatchingCalls)
        assertEquals(null, definitiveStore.current)

        val ambiguousStore = FakePersistence()
        val ambiguousEngine = FakeEngine().apply { createError = LanEngineException("internal_error") }
        val ambiguous = LanHostCoordinator(ambiguousEngine, ambiguousStore, { secrets }, { 1_000L })

        assertThrows(LanEngineException::class.java) { ambiguous.createRoom("Host") }
        assertEquals(0, ambiguousStore.deleteMatchingCalls)
        assertEquals(secrets, ambiguousStore.current)
    }

    @Test
    fun `restore and terminal authority use the persisted host identity`() {
        val secrets = fixtureSecrets()
        val store = FakePersistence().apply { current = secrets }
        val engine = FakeEngine()
        val coordinator = LanHostCoordinator(engine, store, { error("must not generate") }, { 1_000L })

        assertEquals("restored", coordinator.restore())
        assertTrue(engine.restoreRequest.contains(secrets.hostResumeToken))
        assertEquals("closed:resign", coordinator.closeRoom("resign"))
        assertEquals("prepared:true", coordinator.prepareCleanup(true))
        coordinator.deleteActiveRoom()
        assertEquals(listOf("resign"), engine.closeModes)
        assertEquals(listOf(true), engine.cleanupPolicies)
        assertEquals(1, engine.deleteCalls)
    }

    @Test
    fun `existing recoverable bundle blocks create before generation or Go`() {
        val existing = fixtureSecrets()
        val store = FakePersistence().apply { current = existing }
        val engine = FakeEngine()
        var generated = false
        val coordinator = LanHostCoordinator(
            engine,
            store,
            {
                generated = true
                fixtureSecrets().copy(roomId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            },
            { 1_000L },
        )

        val error = assertThrows(LanEngineException::class.java) {
            coordinator.createRoom("Host")
        }

        assertEquals("room_exists", error.code)
        assertFalse(generated)
        assertEquals(0, engine.createCalls)
        assertEquals(existing, store.current)
    }

    private fun fixtureSecrets() = LanRoomSecrets(
        schemaVersion = 1,
        roomId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        roomKey = "room-key-canary-that-must-never-appear-plain",
        tokenPepper = "token-pepper-canary-that-must-never-appear-plain",
        hostPlayerId = "11111111-1111-4111-8111-111111111111",
        hostResumeToken = "host-resume-canary-that-must-never-appear-plain",
    )

    private class FakePersistence(private val order: MutableList<String>? = null) : LanRoomSecretPersistence {
        var current: LanRoomSecrets? = null
        var deleteMatchingCalls = 0

        override fun save(secrets: LanRoomSecrets) {
            order?.add("persist")
            current = secrets
        }

        override fun load(): LanRoomSecrets? = current

        override fun deleteIfMatches(expected: LanRoomSecrets): Boolean {
            deleteMatchingCalls++
            if (current != expected) return false
            current = null
            return true
        }

        override fun delete() {
            current = null
        }
    }

    private class FakeEngine(private val order: MutableList<String>? = null) : LanHostEngine {
        var createRequest = ""
        var restoreRequest = ""
        var createError: RuntimeException? = null
        var createCalls = 0
        val closeModes = mutableListOf<String>()
        val cleanupPolicies = mutableListOf<Boolean>()
        var deleteCalls = 0

        override fun createRoom(requestJson: String): String {
            order?.add("create")
            createCalls++
            createRequest = requestJson
            createError?.let { throw it }
            return "created"
        }

        override fun restore(secretsJson: String): String {
            restoreRequest = secretsJson
            return "restored"
        }

        override fun issueHostLaunch(): String = "launch"

        override fun status(): String = "status"

        override fun closeRoom(mode: String): String {
            closeModes += mode
            return "closed:$mode"
        }

        override fun prepareCleanup(allowMissingGuestAck: Boolean): String {
            cleanupPolicies += allowMissingGuestAck
            return "prepared:$allowMissingGuestAck"
        }

        override fun deleteActiveRoom() {
            deleteCalls++
        }

        override fun stop() = Unit
    }
}
