import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.google.maps.secrets)
}

android {
    namespace = "at.volkshilfe.nachbesuch"
    compileSdk = 36
    defaultConfig {
        applicationId = "at.volkshilfe.nachbesuch.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        // Same marketing version as iOS (MARKETING_VERSION 6.0): the two apps
        // are one product with one changelog, even with separate versionCodes.
        versionName = "6.0"
    }
    signingConfigs {
        // Play-ready signing without committing secrets: create keystore.properties
        // (gitignored, see .gitignore) next to this file with storeFile/storePassword/
        // keyAlias/keyPassword. Without it, release builds stay unsigned and the
        // Play upload remains blocked — deliberately, not silently.
        create("release") {
            val propsFile = rootProject.file("keystore.properties")
            if (propsFile.exists()) {
                val props = Properties()
                propsFile.inputStream().use(props::load)
                storeFile = file(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            // Unsigned until keystore.properties exists (see above).
            if (rootProject.file("keystore.properties").exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            // Minify stays off until a release build is verified on a device:
            // R8 without proven keep rules silently breaks kotlinx-serialization
            // models and Room. The rules live in proguard-rules.pro already.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation(project(":domain"))
    implementation(project(":data"))
    implementation(project(":ui"))
    implementation(libs.androidx.core)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.viewmodel)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.icons)
    implementation(libs.androidx.room.runtime)
    implementation(libs.google.maps.compose)
    implementation(libs.play.services.location)
}

secrets {
    propertiesFileName = "secrets.properties"
    defaultPropertiesFileName = "local.defaults.properties"
}

val verifyGoogleMapsCostPolicy by tasks.registering {
    group = "verification"
    description = "Rejects paid Google Maps services and cloud Map IDs from the Android client."
    doLast {
        val forbiddenArtifacts = setOf(
            "com.google.android.libraries.places:places",
            "com.google.android.libraries.navigation:navigation",
            "com.google.android.gms:play-services-places"
        )
        // Inspect declarations only. Resolving an Android runtime classpath from a
        // generic Gradle task is both expensive and ambiguous for local AAR projects.
        val declared = rootProject.allprojects
            .flatMap { project -> project.configurations.flatMap { it.dependencies } }
            .mapNotNull { dependency ->
                dependency.group?.let { group -> "$group:${dependency.name}" }
            }
            .toSet()
        check(forbiddenArtifacts.none(declared::contains)) {
            "Paid Google client service detected; only the Maps SDK for Android is allowed."
        }

        val source = rootProject.allprojects
            .flatMap { project ->
                project.fileTree("src/main") { include("**/*.kt", "**/*.java") }.files
            }
            .joinToString("\n") { it.readText() }
        check("maps.googleapis.com" !in source && "places.googleapis.com" !in source && "routes.googleapis.com" !in source) {
            "Direct Google Maps web-service calls are forbidden in the mobile client."
        }
        check(".mapId(" !in source && "mapId =" !in source) {
            "A cloud Map ID would switch billing to Dynamic Maps."
        }
    }
}

tasks.named("preBuild").configure { dependsOn(verifyGoogleMapsCostPolicy) }
