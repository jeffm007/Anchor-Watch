pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "NereusAnchorWatch"
include(":shared")
project(":shared").projectDir = file("../shared")
if (!providers.gradleProperty("coreOnly").isPresent) include(":app")
