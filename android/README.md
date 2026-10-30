# Nereus Anchor Watch — Android preview

Open this `android` directory in Android Studio. Android **0.4.0 / build 7** has its own build numbering; the existing Xcode project remains the iOS app.

## Run on this Mac

Android Studio is installed, with a Pixel Fold API 36 ARM64 emulator. Its SDK is now in `~/Library/Android/sdk`; the ignored `local.properties` records that location. The SDK license was accepted with explicit user approval.

1. Open `android` and click **Sync Project with Gradle Files** if prompted. Run remains disabled while sync is in progress.
2. Start Pixel Fold in **Tools → Device Manager**. Select **app** and **Pixel Fold** in the top toolbar, then use **Run → Run 'app'**. The triangle on the lower-left edge opens the output panel; it does not launch the app.
3. Nereus opens on Watch. Enable GPS and allow precise location and notifications. The emulator's location is simulated; it is not the Mac's position.
4. Use Fold/Unfold in the emulator toolbar to review outer and inner screens.

The Upgrade Assistant changed this project to **AGP 9.4.1 / Gradle 9.6.0**, with compatibility flags retained in `gradle.properties`. The daemon configuration selects JetBrains Java 21. Kotlin remains 2.2.20; Compose BOM is 2025.09.00. These versions are pinned, and the wrapper verifies its distribution checksum.

Terminal build with Android Studio's bundled Java:

```sh
export JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home'
cd android
./gradlew :shared:jvmTest :app:assembleDebug :app:lintDebug
```

APK: `android/app/build/outputs/apk/debug/app-debug.apk`.

Core-only tests require Java but no Android SDK:

```sh
cd android
./gradlew -PcoreOnly :shared:jvmTest
```

The shared Kotlin module has no Android APIs. Android consumes its JVM target; `-PenableIos` enables optional Apple targets for later integration. The Swift app does not consume Kotlin yet.

## Build 7 — map tools, sliders, forecasts and hazards

Water now follows the iOS grouped page: depth +/- and inline entry, persisted sounder reference, cosine-interpolated 24-hour depth chart with keel/clearance lines, depth/scope outlook, NOAA current predictions and 100/50/25% scaling, tide events and 6/12/24-hour allowance selection, and scope/radius planning. Numbers use live provider data and the saved boat profile, not screenshot fixtures. Tide adjustment requires prediction coverage at the reading time; no extrapolation is shown. NOAA US coverage remains limited to stations within 25 km; Canadian tide predictions are supported; offline prediction caching is pending. Four Android unit tests cover tide/current interpolation, reference rebasing and nonnegative depth.

Night mode also uses equal left/right panes in landscape and expanded windows: the red boat tracker stays on the left and the night dashboard stays on the right. Compact portrait keeps the stacked night display.

Night mode mirrors the iOS red-on-black watch display with large anchor distance, alarm and rode circles, recent track, wind, next tide, clock and GPS accuracy. Open it from the moon chart control, Alarm menu or Settings. It dims the app window to 5%, hides system bars and keeps the screen awake; exit/background restores previous window settings. Tap to reveal Exit for five seconds, or use Android Back. Monitoring continues and active alarms retain their Silence control.

Landscape handsets and expanded windows (600 dp or wider) use equal left/right panes: the map stays on the left, the selected tab and a two-column Watch dashboard appear on the right, and all four tabs sit below the right pane. Portrait handsets retain the stacked layout. Settings and guides open full-width. Build and lint passed; unfolded Pixel Fold visual review confirmed Watch/Anchor tab switching with the map retained. The emulator locked its outer screen during folding, so compact portrait/landscape interaction review remains required.

Settings now follows the iOS grouped layout: Quick Guide, User Guide, Boat Profile, Anchorage Log, warning preferences/review, gust threshold, Track, Fade Buttons, Metric/Feet, Testing and About. Testing retains Android simulation controls, saved hazards, alarm/rode settings and the siren test. Track adds recording while unanchored; active anchored watches always record. The gust threshold drives available forecast advisories; hiding those banners never hides circle/GPS alarms. Advisory notification delivery and barometer/drift forecasts remain pending.

Boat Profile is editable and saved in SI units, with the iOS Nereus defaults: 47 ft overall, 46.1 ft waterline, 15.7 ft beam, 5.1 ft draft, 62,000 lb dry weight; 1,100/300/64 US gal tanks; 5.5 ft freeboard, 9 ft cabin; Claw 110 lb anchor, 4 ft bow roller; 300 ft of 3/8-inch chain and 20 ft snubber. Full-tank weight (72,841 lb) and estimated front/side windage (181.7/545.1 ft²) match iOS. Clearing windage restores the estimate. Chain/rope selections retain unused lengths, and unit changes preserve stored precision. Existing entered boat length/bow height are retained. Editing boat geometry does not confirm an unmeasured default depth. Real anchor drops/raises now populate a local log (up to 100 entries); earlier watches are not backfilled. Load and holding calculations now use the iOS model described below.

Settings/Profile validation (2026-10-17): all 22 shared tests, debug APK assembly and Android lint passed. Reviewed Settings and all Boat Profile sections on the unfolded Pixel Fold emulator; confirmed the supplied values, numeric editing and persistence after reopening. Initialized this emulator’s overall length and bow roller height to 47 ft and 4 ft as supplied.

Anchor correction: long-press the red anchor, drag it, then release to save. The circle and tether preview the new location while dragging. A white line/readout measures from the original drop; a yellow line/readout shows distance and true bearing from the boat. Drag the text of either readout to reposition it, or tap its × to hide that measurement and its line independently. Starting another anchor drag shows both again. A faded grey anchor marks the original position independently of the readouts. Long-press the grey anchor to remove it and the moved-distance line/readout; the current anchor becomes the reference for the next correction. Readouts follow their lines as the map moves. Cancelling or backgrounding during a drag leaves the saved anchor unchanged. Live corrections and the original drop are saved; simulation corrections remain separate. Radius, rode, track and latched alarms survive correction, and outside-circle confirmation requires fresh fixes.

Anchor correction validation (2026-10-17): all 18 shared tests, debug APK assembly and Android lint passed. The updated APK was installed/launched on Pixel Fold; a full manual long-press, readout drag/close and cancellation interaction review remains required.

- Detailed dark-blue boat with deck/windows/rails; dotted orange tether. All fading toolbar icons are monochrome blue vectors (disabled tools are dimmed), including a folded-map layers icon. Bottom tab icons are 20 dp. Expand dashboard / Collapse dashboard in the Alarm menu toggles the six-card grid.
- Anchor now uses iOS-style inline numeric fields and blue sliders with white capsule thumbs for depth, deployed rode, alarm radius and scope/boat dimensions. Depth, rode and radius apply immediately; radius following is opt-in for existing saved settings and manual radius edits disable following. Following uses entered depth plus manual tide allowance, not a tide-linked low-water estimate. Scope calculator settings retain Save plan. Water retains precise keyboard input and sliders for depth, tide-rise allowance, scope ratio, bow height, boat length and circle margin.
- Open-Meteo provides model wind/gusts and 24 hourly forecast rows in knots. NOAA provides high/low predictions from the nearest station within 25 km, with station/distance, MLLW datum, local time zone, fetched time and explicit errors. Automatic refresh every 15 minutes while foregrounded; manual refresh on Weather/Water. Requests use the current anchor/GPS or simulation location. Simulation weather is real provider data and is not input to scripted motion. Current predictions, Canadian coverage and automatic tide-depth adjustment remain pending.
- Long-press empty chart to add hazards with iOS types/default radii (rock 8 m, shoal 15 m, dock 5 m, boat 30 m, other 10 m), editable 2–80 m keep-clear radius and name. Red symbols/circles persist. Tap to edit/remove; long-press and drag to move, with distance readout. Raising a real anchor hides saved hazards; Settings restores them. Simulation does not hide saved real hazards. Clearance is an estimate from entered geometry; no hazard proximity siren is implemented.
- Google Maps is labeled as requiring setup; see [Google Maps setup](GOOGLE_MAPS_SETUP.md). A Google renderer is pending account/key configuration, not enabled by this build.

## Build 6 — scripted simulation

Open Settings → Simulation. Stop GPS and monitoring first, then choose Swinging at anchor, Wind shift, Dragging anchor, GPS dropout, Wide swing or Slow drag. Select Roche Harbor, WA or Sidney Harbour, BC; a demo anchor and 50 m circle are placed at the selected harbor. Live weather/tides use that simulation origin, independently of the phone GPS. Choose 1×, 5× or 20× speed; Settings → Simulation controls offers Pause/Resume, speed, scenario, restart and exit controls. Selecting a scenario or Restart starts a fresh track. Exit simulation returns to GPS OFF; enable GPS and explicitly resume any saved real anchor.

The SIMULATION banner remains visible on every page. Six scripted position previews and five iOS physical weather scenarios are available. Physical scenarios require confirmed depth and boat inputs; their own weather/tide drives the integrator, while environmental provider cards remain live at the selected harbor. Smooth variations in swing speed, angle and reach add surge and gust-like excursions without random position jumps. The map records the purple track; dragging crosses the circle and raises a visual alarm. Dropout suppresses fixes for simulated seconds 30–75 in every 120-second cycle and shows GPS lost immediately. Alarms remain latched until acknowledged or restarted. Simulation continues while locked through its user-started foreground service when notifications are allowed, and has no automatic siren. If notification access is unavailable it remains a foreground-only preview. It uses a separate monitor and does not persist demo anchors, radius or rode over real settings. Demo tracks are discarded on exit. The boat points toward the marked anchor, with a dotted orange tether (updated in build 7); this is not measured heading.

## Build 5 — map symbols and track

The GPS position uses a dark blue boat symbol and the marked anchor uses a red anchor symbol. Both transparent icons scale smoothly with zoom, from 19.2 dp at zoom 14 to 32 dp at zoom 17 and 57.6 dp at zoom 20, with sizes capped outside that range. The boat icon points toward the marked anchor, with a dotted orange tether (updated in build 7). It does not show measured heading. The existing watch track is purple, consistent with iOS, and uses a thin translucent line. Track recording starts when an anchor is set, resets on a new drop and retains up to 2,000 points in memory. Symbols and track survive chart-layer changes; map gestures never move the anchor.

## Build 4 — resizing chart controls

Tap or drag the map to reveal the tools below the chart: Settings, chart layers, center on GPS/anchor and zoom. They fade over 0.6 seconds after 5 seconds without interaction. The toolbar animates into its own space below the map, shrinking the chart slightly; the chart expands again as the toolbar fades away. The timer pauses during a map gesture or while the layer menu is open, and resets when a tool is used or the app returns to the foreground. Android's accessibility-recommended timeout is respected. Attribution, map errors and monitoring status never fade with the tools.

Settings → Display → **Fade map controls** can keep the toolbar visible; this preference is saved. The User Guide describes the new controls. Build 4 changes no alarm/anchor calculations.

## Build 2 changes and review checklist

The layout follows iOS: black background, dark rounded cards, a compact six-tile grid, a dashboard expand/collapse action in the Alarm menu, an alarm menu with Drop/Raise actions and Watch / Anchor / Water / Weather tabs. The dashboard collapses to give the map more space. Long screens scroll rather than clipping controls.

- **Watch:** OpenSeaMap or NOAA US chart layers; pinch/pan, zoom buttons, My boat/Last fix and Anchor recenter controls. Dark blue is the boat, purple is the track, red is the marked anchor, the ring is the actual alarm circle and translucent blue shows GPS accuracy. Panning and zooming never relocate the anchor; an explicit long-press and drag on the anchor corrects its position. Check that switching tabs or folding does not reset the view or interrupt monitoring.
- **Anchor:** Manual scope planning using measured depth, anticipated tide rise, bow height, boat length and margin. Suggested rode/radius are planning values only. Saving a plan does not change actual rode or the active circle. The iOS holding/load model, catenary and gust limits are available alongside the scope planner.
- **Water:** Confirm sounder depth below the surface, review the tide-adjusted depth chart/outlook, current and tide predictions, and scope recommendations. Without usable tide coverage, planning falls back to entered depth plus the manual rise allowance. Boat dimensions come from Settings → Boat Profile.
- **Weather:** Open-Meteo wind/gust model estimates and hourly forecast; no wind-limit alerts or observation stations yet.
- **Settings:** Open the Watch alarm menu (or Settings on another tab). Edit actual rode/circle, select feet or metres, test the siren and check the current build. All lengths stay in metres internally; saving an unchanged rounded display preserves exact stored values.
- **User Guide:** Open from the alarm menu or a tab's header. It covers the Android functions, terms, monitoring limits, chart operation and actions when alarms sound.

### Exercise monitoring

1. Emulator Extended Controls → Location: send latitude **28.615**, longitude **−96.62**. The map initially browses Port Lavaca if no GPS exists; that initial view is not a position fix. Check accuracy/freshness before marking an anchor.
2. Drop when the anchor enters the water. Zero phone-to-bow offset uses the phone position; an offset requires a user-entered true bearing. Dropping after backing away marks the wrong location.
3. Change longitude to **−96.619**, about 98 m east. Two usable outside fixes should trigger the default 50 m circle alarm. A route or continuous emulator GPS updates is better than a single cached measurement.
4. During the alarm, edit actual rode. The anchor, circle and latched alarm must remain unchanged. Changing the circle is a separate explicit setting.
5. Switch tabs while alarmed: a banner offers a return to Watch. Silence acknowledges sound for 60 seconds; it does not resolve the cause. Raise ends the watch and clears the saved anchor/track.
6. Stop GPS with an anchor set, then enable it again and explicitly resume with fresh fixes. Force-stop/reboot does not leave this preview monitoring; the app reports monitoring OFF on relaunch.

### Map sources and network behavior

MapLibre Native 13.6.1 renders OpenStreetMap base tiles with OpenSeaMap seamarks or the same NOAA ENC export endpoint used by iOS. NOAA coverage is US waters; empty or unavailable chart tiles do not imply safe water. Compare against suitable onboard charts.

Visible attributions and the SDK attribution control credit the providers. Tile requests identify Nereus and use an HTTP cache honoring provider expiry headers. Only normal interactive viewing is implemented: no bulk download or offline-area feature. A connection/tile failure is surfaced while local GPS monitoring continues. Online tile requests reveal the viewed area to the selected providers. No account, API key or tracking backend is required.

## Validation and remaining work

Build 7 (2026-10-17): APK assembly and Android lint passed (no lint errors); all 17 shared tests passed. Public Open-Meteo and NOAA requests returned valid Port Lavaca data. A stuck Java worker held both normal Gradle caches; verification used isolated temporary caches. The new screens and hazard gestures still require an on-device visual/interaction review. Google Maps remains unimplemented pending setup.

Review build 7: open Settings → About and confirm 0.4.0/build 7; start a simulation, check the dashboard toggle in the Alarm menu and blue map toolbar, adjust Anchor/Water sliders, open Weather/Water forecasts, then long-press empty chart to create a hazard and test edit/drag/hide/restore.

Seventeen shared Kotlin tests cover scope/geometry, filtering, accuracy capping, circle confirmation, GPS loss/poor accuracy, rode changes and latched alarms. Shared `../fixtures/scope.csv` also passes the five Swift scope tests. These establish limited numeric/behavioral agreement, not physical holding validation.

Build 1 was smoke-tested on an API 36 ARM64 emulator for GPS permission flow, drop, outside-circle alarm, rode edits and recovery. Build 2 passed shared tests, APK compilation and Android lint (no errors). Visual checks on the inner display confirmed chart rendering, anchor/circle overlays, dashboard collapse, Water → Anchor planning and tab navigation. Normal HTTP 304 cache revalidation is handled without a false tile error. Folding/unfolding was exercised without a runtime crash, but Android locked the outer display, so the outer-screen UI still needs an unlocked review.

Still required before beta/release:

- Port Canadian current services, observed weather stations, advisory notification delivery and remaining platform features. Complete the Google Maps SDK renderer after key setup.
- Extend shared fixtures and recorded GPS replay before replacing any Swift calculation with Kotlin.
- Test real Pixel and Samsung phones: locked-screen overnight monitoring, loss/disabled GPS, permission revocation, volume/DND/Bluetooth routes, process termination, restart and battery restrictions. The earlier headless emulator test did not verify audible output.
- Audit alarm notification escalation, accessibility/large text, power usage, chart coverage and freshness, signing and Google Play foreground-service declarations. The status notification is low importance; the repeating alarm tone comes from the service and may be blocked by the phone's audio policy.
- Wear OS follows proven phone monitoring.

The iOS runtime/UI changes already in the working tree belong to the earlier build 30 rode fixes. This Android milestone does not alter those runtime files or publish either platform to a store.

Environmental loading verification (2026-10-17): added CHS high/low predictions and combined nearest-station selection across the US/Canada border (25 km limit). Live checks returned 24 weather forecast hours at each harbor, NOAA Roche Harbor station 9449834 and CHS Sidney station 5cebf1df3d0f4a073c4bbd26, with tide coverage through October 21. Weather and tides publish independently; canceled/obsolete requests cannot overwrite a newer location. Same-location refresh failures retain previous values with an error and their original fetch time; changing location clears the old data. Forecast location labels identify simulation, anchor or phone GPS. Station lists are cached in memory. To repeat provider checks: `NEREUS_LIVE_CHECK=1 ./gradlew :app:testDebugUnitTest --rerun-tasks`. The physical Galaxy was not connected during this check, so phone GPS behavior was checked through routing tests rather than a field fix.

Emulator review confirmed live Roche Harbor weather, changing simulation origin to Sidney, BC, and a populated Sidney CHS tide card with matching simulation coordinates and datum. NOAA current predictions also loaded at Sidney. Build/lint and all eight Android unit tests (including the opt-in live provider check) passed.

Galaxy follow-up: connected SM-F971U1 by USB, deployed and launched the new debug build, and confirmed precise-location/notification permissions and active GPS requests. Indoors it did not acquire a usable satellite fix; user will test real GPS later. The physical phone subsequently displayed Roche Harbor simulation wind and NOAA tide data successfully. No phone GPS success is claimed yet.

Dashboard tide cards now refresh on a 30-second foreground clock. Tide shows estimated station height above its datum, rise/fall direction and the next high/low time and height. Depth at High Tide uses the next predicted high with a confirmed sounder reference; without one, it explicitly labels entered depth plus manual allowance. Tests distinguish station tide height from actual water depth and reject expired coverage.

Calculation parity port (2026-10-17): AnchorMath covers front/side windage, wind/current forces, waves/yaw/snubber factors, bottom/type holding ratios, chain friction, angle efficiency, chain lift-off, catenary shape, deepest usable chain depth and safe-gust bisection. Anchor controls include seabed/conditions/tide stage and a modeled steady-load diagram. Weather/Anchor show hourly limits and 24-hour depth/scope/gust/swing/slack/hazard risk windows with explicit partial-coverage status. Hull hazard clearance includes interpolated forecast swings, beam and a 5 m position allowance. Radius following and Water's suggested radius now use actual deployed rode and the shallowest available tide-adjusted depth; a manually fixed radius stays fixed.

Watch → Swing analysis and retrieval exposes the robust outer-edge circle fit, error ellipse and wind cross-check, rolling free-fit drift regression with three confirmations, independent distance trend, and bow retrieval guidance. The chart draws the inferred ellipse, drift line and full stern swing envelope; the marked anchor is never moved by an estimate. Pressure is sampled from the handset barometer and stored for a three-hour trend (6 hPa rapid / 3 hPa quick fall). The readiness panel checks alarm volume, battery/charging, permissions and GPS/radius quality. Five deterministic iOS physical weather days drive the optional catenary boat integrator at the selected simulation harbor.

Numerical validation: 27 cases generated by executing iOS AnchoringModel.swift match Android load, anchor pull, reach, lying chain, shank angle, safe gust, holding and status within 1e-6. Nine phone/anchor position snapshots generated by iOS AnchorPhysics.swift also match within 1e-6. Fixtures are under app/src/test/resources; 18 calculation tests include geometry inverses, rope/mixed rode, estimation/drift discrimination, hazard clearance, contiguous coverage, retrieval and pressure history. Modeled advice does not replace a physical holding test. Calculation warnings are displayed in-app; circle/GPS alarms retain the existing siren, and advisory notification delivery is still pending.

### Lock-screen monitoring summary

While live GPS monitoring or a user-started simulation runs, its ongoing notification shows anchor distance in the selected units, circle status, and provider-estimated wind direction/speed/gusts. Expand the notification for all three lines. Simulation notifications are labeled SIMULATION with the harbor and pause state; the simulation advances in the foreground service while the app is locked, without requesting phone GPS or sounding real anchor sirens. The status channel uses normal importance with sound and vibration disabled to avoid low-importance lock-screen filtering. Distance is suppressed when GPS is older than 15 seconds; wind must be recent and within 2 km of the active anchor or current phone location. The foreground service refreshes environmental data every 15 minutes while the UI is paused. Public lock-screen visibility is requested; device/channel privacy settings still control display. Tap the notification to open the app. Circle status does not establish seabed holding.

### Persistent night readings

Settings → Keep anchor data visible in Night mode is enabled by default and persisted. The same switch is available inside Night mode. Leave Nereus open in Night mode to keep distance, circle status, and wind visible on black: touch restores 15% window brightness, 30 minutes of inactivity dims to 5%, and the two-hour blank is skipped while this option and Night mode are both active. Other screens retain the two-hour blank. The power button still locks/sleeps the phone normally; this is an in-app display, not a replacement for the secure lock screen.
