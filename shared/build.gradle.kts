plugins { kotlin("multiplatform") }
kotlin {
    jvmToolchain(17)
    // A pure JVM library is directly consumable by Android; no Android APIs in the core.
    jvm {
        testRuns["test"].executionTask.configure {
            systemProperty("anchor.fixtures", rootProject.file("../fixtures").absolutePath)
        }
    }
    if (providers.gradleProperty("enableIos").isPresent) {
        iosArm64()
        iosSimulatorArm64()
    }
    sourceSets { commonTest.dependencies { implementation(kotlin("test")) } }
}
