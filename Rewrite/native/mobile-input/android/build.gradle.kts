plugins {
    id("com.android.library") version "8.9.1"
    id("org.jetbrains.kotlin.android") version "2.1.20"
}

android {
    namespace = "com.thumble.rewrite.input"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets.getByName("main").java.srcDir("../../../packages/contracts/generated/kotlin")
    sourceSets.getByName("test").resources.srcDir("../../../packages/fixtures")
    sourceSets.getByName("test").resources.srcDir("../../../../Host/fixtures/gamepad")
    testOptions.unitTests.isReturnDefaultValues = false
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
