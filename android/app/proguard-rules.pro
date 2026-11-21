# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-keep,includedescriptorclasses class dev.phonepigeon.proto.**$$serializer { *; }
-keepclassmembers class dev.phonepigeon.proto.** { *** Companion; kotlinx.serialization.KSerializer serializer(...); }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# ML Kit / Firebase-style component discovery instantiates registrars by reflection; without these the QR scanner
# fails to start in release builds ("NoSuchMethodException: ...Registrar.<init>").
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-dontwarn com.google.mlkit.**

# Every @Serializable model (wire messages and the nearby-pairing messages), whichever package it lives in.
-keep,includedescriptorclasses class dev.phonepigeon.**$$serializer { *; }
-keepclassmembers class dev.phonepigeon.** { *** Companion; }
-keepclasseswithmembers class dev.phonepigeon.** { kotlinx.serialization.KSerializer serializer(...); }

# Keep crash reports readable.
-keepattributes SourceFile, LineNumberTable
