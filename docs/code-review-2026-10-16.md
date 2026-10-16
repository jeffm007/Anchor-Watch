# Anchor Watch code and UI review

Reviewed 16 October 2026 against the current working tree, including the seven files with existing uncommitted changes. Application source was left unchanged. This report and four screenshots are saved in the repository.

The app has a substantial foundation: useful GPS rejection rules, independent circle monitoring, explicit stale status on the lock screen and Watch, environmental request generation guards, persistence, retrieval guidance, and extensive tests. The biggest improvements are consistent alarm status, confirmed physical inputs, and reliable behavior over long sessions. Resolve those before expanding the feature set.

## Map crash follow-up — build 26

The physical iPhone debugger backtrace showed a Metal validation assertion during `MKMapView.setFrame`, through VectorKit and `CAMetalLayer.setDrawableSize`. The map now has a persistent UIKit container that rejects invalid or zero sizes, rounds dimensions to screen pixels, skips layout while detached, and applies drawable size changes without animation. The chart frame no longer inherits dashboard and toolbar layout animations; automatic expansion and contraction remain, with immediate map resizing. Metal validation remains enabled.

Validation: 244 simulator tests passed, including repeated resize, zero bounds and detachment regression checks. Xcode rebuilt and launched the app on the selected physical iPhone; the original assertion had not recurred during the initial observation. This does not establish that the device-specific crash is fully resolved; repeated dashboard toggles, menu fade and tab changes on that device remain the acceptance check.

## Follow-up implementation — build 25

The eight remaining follow-ups were implemented in order: audio reset and atomic render gain; tide distance limits and suitability wording; independent NOAA/Canadian observation results; separate shallow intervals; hull and forecast swing clearance; anchorage backup recovery, visible persistence errors and coordinate validation; HTTP/image tile validation, cache expiry and bounded, refreshed wind overlays; accurate automatic precise-location and reverse-geocoding privacy disclosures.

Validation: 242 simulator tests passed with zero failures. This includes regressions for reset recovery, distant tide stations, safe intervals, NOAA outage fallback, malformed tracks, backup recovery, save failure, hull/swing clearance, expired wind and invalid tile responses. Build 25 compiles the iPhone app and its Watch/widget dependencies. Physical-device audio reset, lock-screen/background behavior and overnight endurance still need device testing. The 25 km tide limit is an operational guard, not proof that two locations share a tide regime; forecast swing checks do not predict every possible boat movement. The revised privacy policy is a local document and still needs to be deployed wherever the public policy is hosted.

The findings below describe the original review snapshot; this follow-up records the subsequent implementation.

## Validation and scope

- Built the iPhone app and its Watch and widget dependencies using Xcode.
- Ran the existing unit suite on iPhone 18 Pro Simulator with iOS 27.0: **224 passed, zero failed, zero skipped**. The xcresult summary reported no runtime warnings.
- Inspected the running Watch, Anchor, Water, and Weather tabs. Screenshots: [Watch](reviews/2026-10-16/watch.png), [Anchor](reviews/2026-10-16/anchor.png), [Water](reviews/2026-10-16/water.png), [Weather](reviews/2026-10-16/weather.png).
- Reviewed the monitoring engine, GPS selection, alarm audio, persistence, environmental services, anchoring calculations, drift and swing estimates, maps, Watch communication, Live Activity, app configuration, privacy disclosures, and tests.
- Findings below are established from source unless specifically described as a simulator observation or a risk requiring a device test. Passing unit tests does not establish locked-phone audio reliability, overnight battery life, external GPS behavior, or real-world accuracy of the anchoring model. Watch UI was reviewed in source; a paired Watch was not exercised.

Reproduce the test run with:

```sh
xcodebuild test -project AnchorWatch.xcodeproj -scheme AnchorWatch \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath /private/tmp/anchor-watch-review-build CODE_SIGNING_ALLOWED=NO
```

## High priority findings

### 1 Map track freezes after reaching its point limit

**Confirmed code defect.** `ChartMapView.swift:455` redraws the track only when its count changes. `AnchorWatchEngine.swift:1820` caps the array at 5,000 points by dropping old points. Once full, every append leaves the count unchanged, so the chart continues showing an old polyline while the boat and internal track move.

At the ten-second stationary sampling interval this can occur after about 14 hours; movement of at least half a metre causes faster sampling and an earlier freeze. Detect a track revision or changed final point, and update the polyline after rollover. Add a regression covering more than 5,000 retained samples and a same-count replacement.

### 2 Actual rode length can remain a changing suggestion

**Confirmed state-model problem.** `AnchorWatchEngine.swift:817` derives `rodeSuggested` from high-water depth and carried rode, and `rodeOut` uses that suggestion whenever `rodeOutSet` is nil. `dropAnchor` does not freeze or confirm the deployed length. Thus a later tide download or boat-profile edit can change the reported amount out without anyone paying out chain.

That inferred length feeds swing radius, anchor estimation, clearance and load advice. Explicitly confirm the amount deployed when arming and store it for the anchoring session. Keep recommended rode separate from actual rode. Make radius changes an explicit, visible consequence of editing the actual rode.

### 3 Circle monitoring can wait indefinitely for a swing estimate

**Confirmed behavior with a significant product risk.** A settled drop with unknown bow direction sets `awaitingSwingFix`; `evaluate()` suppresses circle alarms while it remains true (`AnchorWatchEngine.swift:1257,1845`). The fit needs at least 20 minutes after settling and sufficient geometry. There is no timeout requiring action if the fit never becomes usable.

The Watch screen does say “Not armed,” which is good, but the map circle remains green and Anchor can simultaneously say “Holding well.” I observed this combination in the simulator. Add a persistent “Circle alarm OFF” banner with immediate actions to place the anchor manually or use a clearly explained conservative circle. If estimation takes too long, escalate the unresolved setup visibly and audibly rather than leaving a passive wait.

### 4 Holding warnings use different inputs across screens

**Confirmed inconsistency.** `holdingWarning` calls `AnchorMath.forecastWarning` with stored `scope` and default current/waves (`AnchorWatchEngine.swift:828`, `AnchoringModel.swift:416`). The hourly outlook uses tide-adjusted depth and predicted current. The Anchor tab uses its own editable conditions and chosen tide. Consequently the header's warning and detailed outlook can disagree, especially as tide or current strengthens.

Create a shared assessment result with its input time, depth, actual rode, current, waves, and provenance. Derive the dashboard warning from the hourly assessments. Clearly label the Anchor tab as a planning scenario whenever its inputs differ from the monitored session. Test a rising-tide case and a strong-current case across all summaries.

### 5 Media services recovery keeps the old audio engine

**Confirmed implementation gap; hardware outcome needs a device test.** `AlarmPlayer.swift:35` declares the engine as a constant. `rebuildEngine()` at line 200 detaches the source node and recreates it on that same engine. It does not recreate the engine after media services reset.

Apple's recovery guidance calls for disposing orphaned audio objects and creating new ones. Recreate the audio graph and engine, restore the armed/alarming state, and verify the result using the device's media services reset facility. See [Apple QA1749](https://developer.apple.com/library/archive/qa/qa1749/_index.html).

### 6 Audio gain has an unsynchronized cross-thread read and write

**Confirmed concurrency defect; no audible failure reproduced.** `AlarmPlayer.swift:33` stores a mutable `Float` in `Gain`. Main-actor methods write it while the audio render callback reads it. The comment that a briefly stale value is harmless does not provide synchronization.

Use a suitable atomic or another real-time-safe mechanism. Avoid blocking locks or allocation inside the render callback. Exercise repeated alarm/test/silence transitions with a concurrency diagnostic where supported, followed by a real-device stress test.

### 7 Tide station selection has no distance or suitability boundary

**Confirmed validation gap.** `TideService.swift:221` chooses the nearest available US/Canadian station regardless of distance. Unlike the current service, it has no maximum coverage distance. It can return and label tide data usable far from any meaningful station, including inland or outside supported waters. Geographic proximity also does not establish that two locations share a tide regime.

Return no coverage beyond a defensible boundary; expose station selection and distance prominently. Permit a station override and explain that station tide differences are an estimate at the anchorage. Confirm depth-reference compatibility before enabling automated advice.

### 8 High or low water is presented as a definite current reversal

**Confirmed contradictory wording.** The outlook correctly labels high/low water as only a proxy when current predictions are missing. However, `AnchoringModel.swift:391` says “The current reverses around…” using `engine.nextTide?.time`, which is the next high or low, even when actual current predictions exist elsewhere.

Use the next predicted current slack for reversal advice. Without current predictions, use the same uncertainty wording as the outlook and avoid asserting a reversal time. Test that the Anchor tab never substitutes a tide extreme for known slack timing.

## Medium priority defects and inconsistencies

### 9 Units reset on every relaunch

`AnchorWatchEngine.swift:971` initializes units to feet and never saves or loads the selection. Other settings persist. Persist units and verify metric selection survives a fresh engine instance and app relaunch. Consider independent distance, temperature, and weight preferences later.

### 10 Boat profile changes leave derived state temporarily inconsistent

The `boat` observer (`AnchorWatchEngine.swift:275`) only saves. It does not invalidate the outlook or call `followRode`, unlike scope/rode edits. A changed draft, anchor weight, chain size or carried length can update some computed labels immediately while cached hourly advice stays unchanged for up to a minute. If suggested rode changes, the automatic alarm radius may remain based on the previous profile.

Route relevant profile changes through a single recomputation path. With confirmed actual rode from finding 2, changing inventory should not silently alter deployed rode.

### 11 Environmental retry does not retry all data shown with it

`retryEnvironment()` at line 496 retries wind, tide and current. It does not reset or invoke the observation and alert refreshes, although Weather presents it beneath all five providers. “Retry environmental data” therefore cannot immediately retry two listed failures. Retry each provider, retain per-provider errors, and avoid overlapping automatic/manual requests.

### 12 NOAA failure discards otherwise available Canadian observations

`ObservationService.swift:217` begins a Canadian fetch but throws if the NOAA text download fails, before returning the Canadian results. Handle provider results independently and return whatever succeeded with partial-coverage metadata. Add a case with NOAA unavailable and Canada successful.

### 13 Old station readings and alerts remain in prominent UI

`observedWind` and `observedGustAlert` (`AnchorWatchEngine.swift:542`) use the retained observation array without checking current age. `NoticesCard` displays the retained NWS alerts without filtering out newly expired alerts. Failed refreshes preserve these arrays. Provider details may report age, but the headline cards can continue presenting outdated conditions.

Filter and label each reading by measurement age at display time. Remove expired alert notices while retaining an explicitly labeled historical detail if needed. Test time advancing during a network outage.

### 14 Shallow-water windows merge across safe intervals

`TideMath.shallowWindows` (`TideService.swift:101`) iterates only the unsafe points and joins any separated by at most an hour. A safe point between two unsafe points does not close the window. For example, unsafe at 10:00, safe at 10:10, unsafe at 10:20 becomes one continuous unsafe interval.

Process every sample, close a run on a safe sample, and optionally interpolate threshold crossings. This also affects short-scope windows because the same helper is reused.

### 15 Hazard advice checks sampled stern positions rather than the swept hull

`Outlook.hazardItems` (`Outlook.swift:311`) measures distance from the projected stern point to a hazard. It does not check the bow-to-stern segment, boat beam, or the path swept between forecast hours. A hazard alongside the hull or crossed between hourly positions can be missed by this directional forecast, although the separate full-swing clearance calculation provides a useful conservative check.

Evaluate an expanded hull segment and swept arc with uncertainty. Preserve the conservative full-circle check in weak wind/current, where heading is not established. Label the directional overlay as an estimate.

### 16 Persistence failures are silently discarded

`AnchorageLog.save` (`AnchorageLog.swift:68`) suppresses encoding/write errors; load failures become an empty log. Engine settings also suppress encoding errors. A full disk or corrupted log can therefore look like a successful edit or an empty history.

Return errors, retain the last valid file/backup, and show a save failure. Validate decoded values. `trackCoordinates` at line 36 blindly indexes each `[Double]`; a syntactically valid saved track pair with fewer than two numbers can crash the log detail. Use a typed coordinate representation or validate pair lengths and coordinate bounds.

### 17 Chart requests accept HTTP error bodies and ignore freshness

`ChartLayer.swift:27` uses `returnCacheDataElseLoad`, which can return cached tiles without validating expiration. `fetch` forwards response data without inspecting HTTP status or content type. A provider error page may reach the map renderer as image bytes, and old chart tiles can be reused without a freshness indication.

Validate HTTP/image responses and expose a chart loading/failure state. Use cache behavior that respects provider freshness and make chart age/coverage visible. OpenStreetMap requires visible attribution and honoring cache headers; see its [tile usage policy](https://operations.osmfoundation.org/policies/tiles/). The custom layer has no explicit OpenStreetMap attribution; MapKit's generic “Legal” link is not a substitute for the custom provider attribution.

### 18 Wind overlay does not advance with the selected forecast time

`ChartMapView.syncWind` at line 226 keys its rendering by overlay toggle, integer hour offset, and grid fetch identity. It calls `sample(atHour:)` against the current time only when that key changes. Leaving the overlay unchanged can keep old arrows on screen while “now + N hours” advances. Cached grid entries also have no eviction bound, and failed grid fetches can retain older entries without an age label.

Include the resolved forecast time in invalidation, expire displayed values, and bound the cache. Test the same overlay across an hourly boundary with no pan or slider interaction.

### 19 Boat identity is only partly configurable

The Live Activity creates attributes with “Nereus” (`LiveActivityController.swift:73`), the map boat title is “Nereus” (`ChartMapView.swift:149`), and the profile navigation title always adds “2005 Selene 47” (`BoatProfileView.swift:70`). The boat model has a name property but the profile offers no name field.

For a personal Nereus app these defaults are understandable. For any broader use, make name/type editable and propagate identity to every surface. Mark guessed dimensions and tackle values beside the fields until confirmed rather than only in a collapsed footer.

### 20 Privacy wording does not match the requests

The policy says approximate position is sent, but Open-Meteo receives the full coordinate strings and NWS receives four decimal places. `logStay` also reverse-geocodes the anchor coordinate with `CLGeocoder`, a location lookup not explained in the policy's list of uses. The manifest itself declares precise location, which is more consistent with the code.

Describe the actual precision and geocoding use, or deliberately reduce coordinates where appropriate. Clarify that weather and map requests happen automatically once a location is available. Validate final distribution disclosures against the actual shipping behavior.

### 21 Readiness status differs across phone and Watch

The phone header considers critical readiness problems before showing a green holding pill. `publishToWatch()` uses `.holding` to send green unless an audio failure is present; low volume and other critical readiness conditions do not receive the same treatment. The Live Activity has yet another mapping.

Publish one shared monitoring/readiness presentation model to all three surfaces. Distinguish position inside the circle, ability to sound an alarm, and completeness of forecast advice.

## UI assessment and suggested changes

The dark palette, large distance figures, four-tab organization, rode diagram, and night radar are useful. Keep those strengths. The main usability problem is the number of different meanings assigned to a reassuring green status.

### Make monitoring status the clearest element

Use a persistent primary status such as “Circle alarm ON,” “Circle alarm OFF — place anchor,” “GPS interrupted,” or “ALARM.” Place distance, radius and GPS freshness immediately beneath it. Reserve “Holding” for an observed monitoring statement and label modeled results “Estimated capacity” or “Planning result.” A green planning verdict should not look like confirmation that the siren is armed.

The observed Watch screen showed “Finding anchor,” “Not armed,” a green alarm circle, and normal distance/radius figures together. Make the circle dashed/amber while unarmed and state the disabled protection explicitly. Use one status color and phrase across phone, Watch, night view and Live Activity.

### Give the map space and adapt to small screens

The Watch layout is a fixed vertical stack without scrolling or an adaptive arrangement (`ContentView.swift:133`). Six tiles, warning banners, notices, and the toolbar compete with the map. In portrait the layout fits the reviewed simulator, but some tile explanations are truncated; additional alarms, large text and landscape need dedicated checks.

Use two or three primary metrics, then an expandable details panel. Keep alarm actions pinned and permit secondary content to scroll. Switch to a side panel in landscape. Test a smaller iPhone, all accessibility text sizes, multiple simultaneous banners, and VoiceOver before finalizing layout.

### Put weather before diagnostics

The reviewed Weather screen devoted nearly the entire first viewport to provider names, coordinates, fetch ages and long coverage sentences. Put current wind/gusts and the next significant event first, then the forecast chart. Show a concise “Forecast incomplete — depth not confirmed” row that expands into provider diagnostics.

Water duplicated the same missing-depth explanation in two sections. Consolidate it into one actionable prompt: enter depth, choose its reference, and confirm. Show when the reading was measured and whether the displayed value is entered or tide-adjusted.

### Make notice taps predictable

Most of a notice card dismisses it for an hour; only a 32-point chevron opens details (`Dashboard.swift:305`). Users commonly expect tapping the card to open it. Make the entire card open details and provide a distinct hide action. Keep critical readiness problems visible while they persist. Turn “+N more” into a button opening the full list.

### Improve inputs and accessibility

- Add accessible names to icon-only toolbar buttons, depth plus/minus buttons, and custom map markers. `RoundButton` exposes the SF Symbol without an explicit action label. Use action names such as “Recenter chart” rather than symbol names.
- Increase fine-tune arrows from 40 to at least 44 points and notice detail targets from 32 to at least 44. Add VoiceOver values and hints for sliders and chart annotations.
- Allow direct numeric entry for rode and radius alongside sliders; a wet-finger slider is difficult for precise changes. Add a clear keypad Done action consistently.
- Explain the sounder reference: depth below surface, below transducer, or below keel. The calculations assume water depth, but the entry prompt only says sounder reading.
- Separate measured values, forecasts and assumptions visually. “Current here” should always show the station speed, applied scaling, and that scaling's assumption.
- Show force as lbf/kgf when appropriate; `formatForce` currently prints lb/kg, which can be mistaken for mass.
- Consider an optional daylight palette and stronger contrast for secondary captions. Retain the red night mode.

### Avoid overly exact confidence language

“Good to 10 kt” and “Holding well” imply more certainty than rough holding ratios, assumed waves/current and guessed boat inputs justify. The simulator showed a green verdict with a rounded gust equal to the rounded limit, making the margin hard to assess. Present an estimated capacity range or a clear margin and list missing inputs adjacent to the verdict. An expert should validate the model and thresholds against independent examples before these values become a central promise of the app.

## Engineering improvements

1. Split the nearly 2,000-line engine into session state, GPS monitoring, environmental fetching, advice calculation, and persistence. Preserve the injected clock and provider boundaries.
2. Use the injected clock consistently. Production `Date()` still appears in drop time, drift correction age, device polling, simulation, weather refreshes and log timing; this makes time-based tests and simulation behavior harder to reason about.
3. Make `start()` idempotent and manage observers/timers explicitly. Repeated calls currently create new battery observers and watchdog timers.
4. Serialize or version each provider's concurrent refreshes. Generation guards prevent old-location results, but two same-location requests can still complete out of order. A manual retry and the automatic scheduler can overlap.
5. Model actual input validity centrally: finite numbers, coordinate bounds, nonnegative dimensions, actual rode within inventory, depth reference, and confirmed versus assumed values. UI clamping alone does not protect decoded state.
6. Separate simulation sessions from real monitoring, stored anchorages and live weather. Switching position source currently preserves the active anchor. Require an explicit transition when monitoring is active, and prevent practice sessions from being mistaken for real history. Simulated tide and wind should feed the same advice pipeline rather than mixing simulated current conditions with real future forecasts.
7. Add a short README covering build generation from `project.yml`, supported OS targets, test invocation, provider coverage, and physical-device validation. Add CI for the existing suite and a small number of meaningful UI regressions.

## Features worth adding

| Priority | Feature | Benefit and scope |
| --- | --- | --- |
| First | Guided arming check | Confirm real GPS, anchor placement, actual rode, depth reference, volume/output and a siren test; finish with unmistakable alarm status. |
| First | Alarm event history | Record alarm cause, time, GPS quality, radius, distance, silence and recovery. Useful for explaining overnight false alarms and diagnosing a missed warning. |
| First | Confirmed input tracking | Mark measured, estimated and default boat/depth/tackle values; show missing confirmations beside advice. Include configurable phone/GPS position relative to bow. |
| Next | Session recovery summary | On relaunch, show restored anchor, deployed rode, unavailable track history, current GPS freshness and siren readiness. Require action for materially incomplete recovery. |
| Next | Anchorage and track export | Export GPX/CSV plus notes; provide backup and restore with validation. Keep existing local-first behavior. |
| Next | Better hazard geometry | Hull and swept-area clearance, uncertainty, and conservative full-swing warnings in light air. |
| Next | Watch connection health | Clear connection/freshness status and an explicit explanation of when wrist haptics work. The current repeating haptic is driven by a foreground timer; do not promise an independent overnight Watch alarm without a validated implementation. |
| Later | Marine instrument input | NMEA 0183/2000 gateway support for depth, heading, wind and external position, with source selection and freshness checks. Heading would improve slow-speed bow placement and retrieval. |
| Later | Verified offline coverage | A visible list of downloaded regions, zoom range and chart age, using a provider that permits offline downloads. Do not bulk-download the current OSM standard tile endpoint. |
| Later | Remote crew notification | Optional alerts to a second device with delivery acknowledgement and clear dependency on connectivity. Implement only after local alarm reliability is established. |

For a personal Nereus app, multiple boat profiles and broad international weather support are lower priority than reliable overnight monitoring and fewer setup ambiguities. For public distribution, editable identity, onboarding, provider attribution and explicit regional coverage become essential product work. Open-Meteo's free endpoint is for non-commercial use; evaluate the appropriate service before commercial distribution and add its required attribution. See [Open-Meteo terms](https://open-meteo.com/en/terms).

## Suggested implementation order

1. Confirm actual rode; resolve the indefinite unarmed state; unify monitoring/readiness status and capacity calculations.
2. Repair media-reset recovery and gain synchronization; add device-level audio interruption and overnight checks.
3. Fix track rollover, unit persistence, stale observations/alerts, tide coverage boundaries and incorrect reversal wording.
4. Fix provider retries/fallbacks, shallow windows, profile invalidation, chart freshness and persistence errors.
5. Simplify Watch/Weather layouts, improve accessibility and numeric entry, then add event history and exports.

## Additional validation before relying on a release

Run a physical-device matrix covering locked screen, backgrounding, Focus, silent switch, low/zero volume, Bluetooth connect/disconnect, phone calls, Siri, route changes, media reset, denied/revoked permissions, reduced GPS accuracy, external GPS loss, offline/reconnect, low battery/unplugging, crash/relaunch, and an overnight session beyond the track limit. Confirm alarm onset and recovery with actual sound and timestamps. Test the minimum supported iOS/watchOS versions as well as the current simulator runtime.

Add targeted regression tests for findings 1–4, 9–18 and 21. Include malformed saved state and out-of-order provider replies. Validate anchoring calculations against independent reference cases rather than relying solely on tests that encode the same formulas. No physical vessel trial or audio-route reliability certification was performed as part of this review.
