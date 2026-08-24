package me.zqydev.gamebox

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NicknameRulesAarTest {
    @Test
    fun everySharedFixtureUsesTheGoAarNormalization() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val fixture = context.assets.open("nickname_cases.json")
            .bufferedReader(Charsets.UTF_8)
            .use { JSONObject(it.readText()) }
        assertEquals(1, fixture.getInt("schemaVersion"))
        val cases = fixture.getJSONArray("cases")
        assertTrue(cases.length() > 0)
        val targetContext = context.createPackageContext(
            "me.zqydev.gamebox",
            Context.CONTEXT_INCLUDE_CODE or Context.CONTEXT_IGNORE_SECURITY,
        )
        val channelClass = targetContext.classLoader.loadClass(
            "me.zqydev.gamebox.AppProfileChannel",
        )
        val companion = channelClass.getDeclaredField("Companion").get(null)
        val normalize = companion.javaClass
            .getDeclaredMethod("normalizeNickname", String::class.java)
            .apply { isAccessible = true }

        for (index in 0 until cases.length()) {
            val testCase = cases.getJSONObject(index)
            val result = normalize.invoke(companion, testCase.getString("input")) as String?
            val expected = testCase.getString("display").takeIf { testCase.getBoolean("valid") }
            assertEquals(testCase.getString("name"), expected, result)
        }
    }
}
