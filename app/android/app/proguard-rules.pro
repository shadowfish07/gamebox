# Godot's native runtime resolves these Java classes and methods by their exact
# JNI names. R8 must not rename or remove any part of the Android bridge.
-keep class org.godotengine.godot.** { *; }
