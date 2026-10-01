pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        // The Connect IQ companion SDK lives on Maven Central.
        mavenCentral()
    }
}

rootProject.name = "TreeMapper Garmin Demo"
include(":app")
