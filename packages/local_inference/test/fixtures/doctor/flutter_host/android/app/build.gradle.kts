plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.fixture"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        applicationId = "com.example.fixture"
        // The runtime gate of local_inference_flutter is API 28; minSdk 21 would only be refused at run time.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }
}

flutter {
    source = "../.."
}
