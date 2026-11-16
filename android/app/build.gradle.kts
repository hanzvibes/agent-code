import java.io.File
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.codeharness.code_harness"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.codeharness.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Tier 2: libnode.so is too big for the GitHub Git Data API (HTTP 422
// "input was too large" at ~48 MB), so it is stored as ~10 MB chunks
// (libnode.so.chunk00..04, committed) and reassembled here before the JNI
// libs are merged into the APK. The reassembled file is byte-identical to
// the staged original (verified by sha256 below) and is .gitignored, so a
// fresh checkout rebuilds it automatically on the first build.
val libnodeSha256 = mapOf(
    "arm64-v8a" to "72e6374bfe3b1b579466a620690f0f02ba05143712bc19669e186888ada33193",
    "x86_64" to "34553b4de4590caa51fcf78db4e11609f82babe9c51e36e2e1b83bed90cc2384"
)

fun sha256Hex(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(1024 * 1024)
        var read: Int
        while (input.read(buffer).also { read = it } != -1) {
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}

val reassembleLibnode = tasks.register("reassembleLibnode") {
    group = "build"
    description = "Reassembles libnode.so from committed ~10 MB chunks (Tier 2)."
    // Always run the cheap check: skip per ABI when the .so already exists
    // with the expected hash; rebuild from chunks otherwise (idempotent).
    outputs.upToDateWhen { false }
    doLast {
        val jniLibsDir = layout.projectDirectory.dir("src/main/jniLibs")
        for ((abi, expectedSha) in libnodeSha256) {
            val abiDir = jniLibsDir.dir(abi).asFile
            val target = File(abiDir, "libnode.so")
            val chunks = abiDir.listFiles { f -> f.name.startsWith("libnode.so.chunk") }
                ?.sortedBy { it.name } ?: emptyList()
            if (target.exists() && sha256Hex(target) == expectedSha) {
                logger.lifecycle("reassembleLibnode: $abi/libnode.so already present with matching sha256, skipping.")
                continue
            }
            check(chunks.isNotEmpty()) {
                "reassembleLibnode: no libnode.so.chunk* files found in $abiDir and libnode.so is missing or corrupt; cannot build the Tier 2 node runtime."
            }
            logger.lifecycle("reassembleLibnode: reassembling $abi/libnode.so from ${chunks.size} chunks.")
            val tmp = File(abiDir, "libnode.so.tmp")
            tmp.outputStream().use { out ->
                for (chunk in chunks) {
                    chunk.inputStream().use { it.copyTo(out) }
                }
            }
            val actualSha = sha256Hex(tmp)
            check(actualSha == expectedSha) {
                "reassembleLibnode: reassembled $abi/libnode.so sha256 mismatch: expected $expectedSha, got $actualSha."
            }
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            logger.lifecycle("reassembleLibnode: $abi/libnode.so reassembled (${target.length()} B, sha256 OK).")
        }
    }
}

// Runs before every JNI merge (AGP 8.x names it merge<Variant>JniLibFolders,
// e.g. mergeDebugJniLibFolders / mergeReleaseJniLibFolders — NOT
// "JniLibs"), so the reassembled libnode.so is what gets packaged into the
// APK. The "JniLib" substring matches both spellings, including the
// per-ABI variants used by `flutter build apk --split-per-abi`.
tasks.matching { it.name.startsWith("merge") && it.name.contains("JniLib") }
    .configureEach { dependsOn(reassembleLibnode) }
