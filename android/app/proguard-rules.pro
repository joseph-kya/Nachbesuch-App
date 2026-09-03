# Keep rules for a future minified release build (isMinifyEnabled is off until
# a release build is verified on a device). Without these, R8 silently breaks
# the kotlinx-serialization backup models and the Room entities/DAOs.
-keepattributes Signature, InnerClasses, EnclosingMethod
-keepattributes RuntimeVisibleAnnotations, AnnotationDefault

# kotlinx-serialization: keep generated serializers and their companion fields.
-keepclassmembers class ** {
    *** Companion;
}
-keepclasseswithmembernames class ** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Room: entities, DAOs and the database implementation are referenced by name.
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *
-keep @androidx.room.Dao class *
