# Anchor Watch project map

Navigation checked against the working tree on 2026-10-26. This is a starting map, not a fresh feature audit or release certification. Paths below are relative to the repository root.

## Choose the relevant area

| Area | Start here | Related code / tests |
| --- | --- | --- |
| iOS app entry and screen routing | `AnchorWatch/App/AnchorWatchApp.swift`, `AnchorWatch/UI/ContentView.swift` | `AnchorWatch/UI/` |
| iOS monitoring, GPS, readiness and alarms | `AnchorWatch/Core/AnchorWatchEngine.swift` | `GPSLocationSource.swift`, `Readiness.swift`, `AlertService.swift`, `AlarmPlayer.swift` in the same directory; `Tests/AnchorWatchTests.swift` |
| iOS anchoring calculations | `AnchorWatch/Core/AnchoringModel.swift`, `AnchorWatch/Core/AnchorPhysics.swift` | `ScopeCalculator.swift`, `AnchorEstimate.swift`, `AnchorDrift.swift`; `Tests/AnchorWatchTests.swift` |
| iOS environmental data | `AnchorWatch/Core/TideService.swift`, `AnchorWatch/Core/CurrentService.swift` | `WindService.swift`, `ObservationService.swift`, `ValidatedBCTides.swift`, `Barometer.swift` |
| iOS maps and offline charts | `AnchorWatch/UI/ChartMapView.swift`, `AnchorWatch/UI/OfflineENCView.swift` | `AnchorWatch/Core/OfflineChart.swift`, `AnchorWatch/Resources/` |
| Apple Watch and Live Activities | `AnchorWatchWatch/AnchorWatchWatchApp.swift` | `AnchorWatch/Core/WatchLink.swift`, `AnchorWatchWidgets/AnchorLiveActivity.swift`, `AnchorWatchShared/AnchorActivity.swift` |
| Android entry and navigation | `android/app/src/main/java/com/nereus/anchorwatch/MainActivity.kt` | `AppScreens.kt`, `WatchScreen.kt`, `SettingsHub.kt` in the same package |
| Android monitoring and environment | `android/app/src/main/java/com/nereus/anchorwatch/WatchSession.kt` | `MonitoringService.kt`, `EnvironmentClient.kt`, `EnvironmentData.kt`, `WaterMath.kt` in the same package |
| Android calculations | `android/app/src/main/java/com/nereus/anchorwatch/calculations/` | `android/app/src/test/java/com/nereus/anchorwatch/CalculationParityTest.kt` |
| Shared Kotlin core | `shared/src/commonMain/kotlin/com/nereus/anchorwatch/core/` | `AnchorMonitor.kt`, `Simulation.kt`, `BoatProfile.kt`; `shared/src/commonTest/` and `shared/src/jvmTest/` |
| Numeric parity fixtures | `fixtures/`, `android/app/src/test/resources/` | `android/app/src/test/resources/README.md` explains fixture provenance |

Swift and Kotlin implementations coexist. Do not assume a shared Kotlin change automatically changes iOS behavior. Check both implementations and parity tests when a calculation or monitoring contract changes.

## Build and test entry points

Run wrapper scripts from the repository root; the individual scripts assume that working directory.

| Change | Existing command |
| --- | --- |
| iOS source | `./scripts/test-ios.sh` |
| Shared Kotlin source | `./scripts/test-shared.sh` and `./scripts/test-android.sh` |
| Android source | `./scripts/test-android.sh` |
| Multiple platforms | `./scripts/test-all.sh` |

The iOS script invokes `xcodebuild test -scheme AnchorWatch` on the **iPhone 18 Pro** simulator with `ONLY_ACTIVE_ARCH=NO` and `CODE_SIGNING_ALLOWED=NO`. Verify that destination exists before execution; report an unavailable runtime rather than changing signing or silently skipping tests.

The Kotlin scripts use the wrapper under `android/`. `android/settings.gradle.kts` includes `../shared`; `-PcoreOnly` excludes the Android app. A core-only alternative is `(cd android && ./gradlew -PcoreOnly :shared:jvmTest)`.

For Android assembly and lint, the documented command is `(cd android && ./gradlew :shared:jvmTest :app:assembleDebug :app:lintDebug)`. The Android README specifies Android Studio's bundled Java at `/Applications/Android Studio.app/Contents/jbr/Contents/Home`. Verify local prerequisites instead of installing or changing SDKs automatically.

`project.yml` defines the Apple targets and scheme; `AnchorWatch.xcodeproj/` is the Xcode project. Inspect both before build-configuration edits. Do not regenerate the project as a routine review step.

These commands were checked against scripts/configuration, not executed during this documentation update. Test counts and run times vary; report current output.

## Documentation and known validation limits

- `android/README.md`: Android setup and dated implementation/validation notes. It includes historical sections; verify current behavior in source before repeating a limitation.
- `docs/code-review-2026-10-16.md`: historical review findings, not a current bug list.
- `docs/privacy-policy.md`: privacy document; do not infer deployment status from file existence.
- Simulator/JVM tests and cross-platform numerical agreement do not establish on-vessel safety, overnight alarm reliability, or current provider coverage. Claim those only with task-relevant evidence.
- Offline chart and tide-related source files now exist. Do not reuse an older blanket claim that offline functionality is absent; inspect the relevant implementation when asked.

Avoid reading `build/`, `android/.gradle/`, `android/app/build/`, IDE caches, assets, or entire fixture datasets unless the specific task requires them. Never read credentials or local secret files just to understand the project.
