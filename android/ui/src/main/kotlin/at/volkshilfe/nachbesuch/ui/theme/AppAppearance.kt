package at.volkshilfe.nachbesuch.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Light/dark override, mirroring the iOS `AppAppearance` and its
 * `appearance.mode` @AppStorage key.
 *
 * [SYSTEM] deliberately carries no scheme of its own — it defers to
 * `isSystemInDarkTheme()` at render time rather than resolving once at launch,
 * so following the system switch does not need an app restart.
 */
enum class AppAppearance(val storageValue: String, val title: String) {
    SYSTEM("system", "System"),
    LIGHT("light", "Hell"),
    DARK("dark", "Dunkel");

    companion object {
        fun from(raw: String?): AppAppearance =
            entries.firstOrNull { it.storageValue == raw } ?: SYSTEM
    }
}

/**
 * The accent palette, mirroring iOS `AppAccent` / `appearance.accent`.
 *
 * Each accent carries a separate [dark] tone rather than reusing one colour for
 * both schemes: the iOS palette leans on system colours that already adapt, and
 * using the light tone on the near-black background here fails contrast.
 */
enum class AppAccent(
    val storageValue: String,
    val title: String,
    val light: Color,
    val dark: Color,
    val lightContainer: Color,
    val darkContainer: Color
) {
    VOLKSHILFE("volkshilfe", "Volkshilfe", VolkshilfeRed, Color(0xFFFF6961), Color(0xFFFFDAD9), Color(0xFF930010)),
    ORANGE("orange", "Orange", Color(0xFFC85000), Color(0xFFFF9F4A), Color(0xFFFFDCC4), Color(0xFF8A3700)),
    BLUE("blue", "Blau", Color(0xFF0A62C8), Color(0xFF7DB4FF), Color(0xFFD4E3FF), Color(0xFF004787)),
    PURPLE("purple", "Violett", Color(0xFF6B4EA8), Color(0xFFC9B2FF), Color(0xFFE9DDFF), Color(0xFF4A2F86));

    companion object {
        fun from(raw: String?): AppAccent =
            entries.firstOrNull { it.storageValue == raw } ?: VOLKSHILFE
    }
}
