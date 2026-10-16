import SwiftUI

/// The numbers the guide quotes. A test checks these against the engine's real settings, so the
/// guide can't quietly go out of date when a threshold changes.
enum GuideFacts {
    static let confirmFixes = 2
    static let gpsLostSeconds = 30
    static let gpsPoorSeconds = 60
    static let snoozeSeconds = 60
    static let batterySnoozeMinutes = 10
    static let controlsFadeSeconds = 6
    static let goodAccuracyMeters = 8.0
    static let unusableAccuracyMeters = 50.0
    static let discountCapPercent = 30
    static let batteryNoticePercent = 20
    static let batteryAlarmPercent = 10
    static let batteryWarnPercent = 30
    static let gustDefaultKnots = 25
    static let windShiftDegrees = 60
    static let averagingSeconds = 8
    static let liveActivityStaleMinutes = 2
}

struct GuideTopic: Identifiable {
    enum Block {
        case heading(String)
        case text(String)
        case bullets([String])
        case tip(String)
        case warning(String)
        /// Equations and tables, in a fixed-width font that scrolls sideways if it's wide.
        case formula(String)
    }

    let id: String
    let title: String
    let icon: String
    let blocks: [Block]
}

enum UserGuideContent {
    static let sections: [(title: String, topics: [GuideTopic])] = [
        ("Getting started", [quickStart, mainScreen]),
        ("Keeping watch", [anchoringTutorial, settingAnchor, alarmCircle, alarms, watchCheck, lockScreen, appleWatch]),
        ("Charts and weather", [charts, wind, tides, canada]),
        ("Reference", [settings, anchorMath, troubleshooting, dataSources, safety]),
    ]

    static var topics: [GuideTopic] { sections.flatMap(\.topics) }

    // MARK: Getting started

    static let quickStart = GuideTopic(id: "quickstart", title: "Quick start", icon: "flag.checkered", blocks: [
        .text("Anchor Watch uses your iPhone's GPS to follow Nereus relative to where the anchor was dropped, and sounds an alarm if the boat leaves a circle you choose."),
        .heading("First time only"),
        .bullets([
            "Allow **Location** when asked, and choose **Always**, so watching continues with the screen off.",
            "Allow **Notifications**, so alarms and weather alerts reach you in the background.",
            "Open **Settings → Testing → Position source** and choose **iPhone GPS** for real monitoring.",
            "Open **Settings → Testing → Watch check and test siren** and tap **Test siren now** to hear how loud the alarm is.",
        ]),
        .heading("Each time you anchor"),
        .bullets([
            "Prepare the app and check GPS before the maneuver. Mark the drop when safe, or enter the anchor after setting it; verify the position afterward.",
            "Tap **Drop Anchor Here** (or the status at the top) and say where the anchor is: **Anchor going down now** if you tap it as it goes over the bow, or **Boat has settled on the rode** if you've already fallen back. Confirm the actual rode deployed and verify the mark. An amber dashed circle and **Circle alarm OFF** mean the anchor position still needs resolving; do not assume monitoring is active.",
            "Set the circle with **Alarm radius** on the **Anchor** tab. The **Water** tab works out how much rode to pay out and a suggested radius.",
            "Plug the phone in, turn the volume up, and glance at the **Watch check** if an orange or red bar shows.",
            "Maintain a watch appropriate to conditions. Check the set, weather, swing room and alarm readiness before settling in; read **Setting an anchor — tutorial** for the full sequence.",
        ]),
        .heading("When you leave"),
        .bullets(["Tap **Raise** on the Anchor tab to stop watching. The circle, track and lock-screen card all go away."]),
        .tip("Try the whole thing at the dock first, using **Test siren in 15 seconds** and locking the phone, so you know the alarm works before you rely on it."),
    ])

    static let mainScreen = GuideTopic(id: "mainscreen", title: "The main screen", icon: "iphone", blocks: [
        .heading("Top"),
        .text("The boat's name, the GPS in use with its accuracy (green good, orange poor, red too poor to use), and a compact alarm control on the right: **Alarm ON**, **Alarm OFF**, **Check alarm**, **GPS interrupted**, or a movement/alarm warning. It stays at Outside circle after you silence the alarm, until the boat is back inside."),
        .text("**Tap the circle alarm status** to drop the anchor when you're not anchored, or to raise it (or silence the alarm) when you are. When anchored, this menu also offers **Warnings** and **Retrieve Anchor**. Raising or retrieving ends circle monitoring and requires a deliberate choice."),
        .heading("Dashboard grid"),
        .text("The six dashboard tiles are shown at the top by default. Tap **Dashboard** to collapse or expand the grid; your choice is remembered. The map fills the space released by the grid, dismissed notices and fading toolbar. The map expands or contracts immediately."),
        .bullets([
            "**Wind**: forecast speed with an arrow showing which way it blows, where it comes from and the gusts. Tap for the Weather tab.",
            "**Depth at High Tide**: the depth at the next high water (today's depth plus how much the tide will rise), with the depth now and the time of the high underneath. Tap for the Water tab.",
            "**Scope**: rode out against today's depth plus bow height. It drops as the tide rises. The deployed rode is frozen when you drop anchor; later recommendations do not change it. **Unconfirmed** means you still need to verify that length. Use **Confirm rode** or **Edit rode** when offered; Raise clears the deployed length. Tap for the Anchor tab.",
            "**Anchor**: **Holding** means no position alarm condition has been detected; it is not proof of a securely set anchor. Read the accompanying status for readiness, GPS interruptions or an unresolved anchor position. Modeled capacity is a separate planning assessment on Anchor.",
            "**Tide**: how much it will rise or fall to the next high or low, and when. Tap for the Water tab. Once you've marked hazards it becomes **Clearance**: the gap between your stern at full swing and the nearest hazard (orange when close, red if the swing reaches it).",
            "**Distance**: from the anchor now, the furthest so far (Max), and the alarm radius. Orange near the circle, red outside it.",
        ]),
        .heading("Night mode"),
        .text("The **moon button** in the row of buttons under the chart turns the screen black and red and dims it right down, so it won't spoil your night vision: the status, the distance from the anchor and the alarm radius, a small radar of the circle with the boat's position, and the wind, next tide, time and GPS accuracy. **Tap anywhere** to show Exit; leaving puts the brightness back. The watch keeps running, and an alarm shows in night mode with its **Silence** button."),
        .heading("Anchorage log"),
        .text("When you raise the anchor after ten minutes or more, the stay is saved to **Settings → Anchorage Log**: where (named from the map), when, depth, rode, bottom, alarm radius, furthest swing and the track. Open one to see the track on a map, note **how it held**, add notes, rename or delete it. **Swipe a stay left** for **Delete** or **Lock**: a locked stay shows a padlock and can't be deleted until you swipe again to **Unlock** (or turn **Locked** off on its page). When you anchor within about 500 ft of a logged spot, a notice shows that visit; tapping the notice uses the same rode and bottom. Swipe the notice left or tap its × to dismiss it for this anchoring session; the map expands into the freed space."),
        .heading("Barometer"),
        .text("The phone's own pressure sensor is read about once a minute. If it falls **3 hPa in 3 hours**, a notice says wind is likely; **6 hPa or more** is shown in red as a gale risk. These weather notices are separate from circle monitoring. A notification is sent when a threshold is newly crossed unless **Silence advisory notifications** is enabled. The Weather tab shows the reading, the 3-hour change and 6 hours of history."),
        .heading("Hazards"),
        .text("**Long-press an empty spot on the chart** to mark a rock, shoal, dock, another boat or anything else to keep clear of, with how far to stay off and a name. It shows as a red badge with a red circle. Tap a badge to see it: **Edit** changes its kind, keep-off distance or name, and **Remove** deletes it. **Long-press a badge and drag** to move it, just like the anchor: a yellow line gives its distance and bearing from the boat, a white one how far it moved, and the labels close with their ✕. Raise or Retrieve hides all marked hazards immediately, including their clearance and outlook warnings. Tap **Hidden hazards** below the chart to restore individual marks or permanently delete them. Hidden marks survive closing the app and further raises; dropping anchor never restores them automatically. Restored marks keep their original map positions, so fixed rocks and docks stay put when you move the boat. The outlook estimates hull and swing clearance from forecast wind and current, including beam and a position allowance. Unforecast swings and unmarked hazards remain possible."),
        .heading("Next 24 hours"),
        .text("Under the tiles, the app looks ahead through the tide predictions and the wind forecast and shows the **next potential problem in the available forecast**, with a countdown: thin water under the keel at low tide, short scope at high water, forecast gusts beyond what your setup holds (worked out again for each hour, since high water's shorter scope holds less), or a **swing**. Green means no issue was found in available inputs; incomplete or inaccurate data can miss a risk. **Tap it** for the full list in time order, including smaller wind shifts and slack water. **Swipe a warning left** for **Delete** or **Lock**. **Lock** keeps it in the list with a padlock and stops it being deleted; swipe again to **Unlock**. A deleted warning stays gone as the forecast is redone, and comes back only if it gets worse (a swing that comes within 20 ft becoming one that reaches the hazard, say). Deleting a hazard warning hides every warning about that hazard. **Show hidden** at the bottom brings them back, and a new anchoring starts afresh."),
        .heading("Swings and anchor resets"),
        .text("Each hour the app works out which way the boat lies from the wind's push on the windage and the current's push on the hull together. When that turns by 90° or more, the boat swings round and the anchor has to turn and reset, so it's flagged with the cause: the wind going round, or the flood or ebb taking over in light wind. Current comes from the nearest NOAA current station (see the Water tab). Without current predictions, high/low water is only a proxy for a possible turn. It does not establish the time of current reversal or slack; actual timing and swing remain unknown."),
        .heading("Notices"),
        .text("Under the chart: anything to look at now that isn't an alarm: weather alerts, gusts measured nearby and watch problems. Forecast trouble is in Next 24 hours above. Tap a notice to open its details; use its **×** or swipe left to hide an advisory. Critical monitoring problems remain visible. **Settings → Warnings** can hide advisory banners or silence weather/barometer notifications; **Alarm ON → Warnings** opens the retained warnings."),
        .heading("Tabs along the bottom"),
        .bullets([
            "**Watch**: this screen: status, position and the chart.",
            "**Anchor**: monitoring status followed by **Planning scenario · estimated capacity**, the modeled gust threshold and the next 12 hours of available forecast, the rode drawn from the side at low, now or high tide, your setup, the alarm radius and anchor controls, then **Conditions**, **Load analysis** and **Your boat**, which open with a tap.",
            "**Water**: the depth you set, then the depth over the next 24 hours with your keel line, the lowest and highest water, how your scope changes and warnings if the water gets thin; the **Current** from the nearest NOAA current station (now, the next slacks and strongest flood and ebb, and how much of the station's speed reaches your anchorage); and the tide and scope settings.",
            "**Weather**: the wind and gusts for the next 24 hours against the gust your setup holds at each hour, with the direction, then the wind outlook and nearby station readings.",
        ]),
        .heading("Buttons under the chart"),
        .bullets([
            "**Gear**: Settings, Boat Profile, Testing and this guide.",
            "**Map**: choose the chart.",
            "**Wind**: show the wind forecast on the chart.",
            "**Target**: re-centre the chart on the boat and anchor.",
            "**+ and −**: zoom. You can also pinch and drag the chart with your fingers.",
        ]),
        .text("These stay on screen unless you turn on **Settings → Fade Buttons**. Then they fade after \(GuideFacts.controlsFadeSeconds) seconds; **tap the chart** to bring them back."),
        .heading("On the chart"),
        .bullets([
            "The blue **boat** is drawn to the real size of Nereus (47 ft) and points toward the anchor, as a boat lying to its rode does.",
            "The **anchor** symbol’s red point is the current recorded anchor mark—estimated from the drop, corrected from swing, or manually placed. Check it against the actual drop position.",
            "The dashed line runs from the anchor to the bow.",
            "The small **dotted orange circle** round the anchor shows how far off the drop point may be: the GPS accuracy (±) when you dropped, plus the uncertainty in which way the bow pointed. This is an uncertainty illustration, not a guaranteed containment probability for the actual anchor. It disappears if you move the anchor by hand.",
            "The purple line is the **track** of where the boat has been. It starts when you drop the anchor, or as soon as you're moving if **Settings → Track** is on.",
            "The label under the circle shows whether the **Circle alarm is ON or OFF**, with the radius. The circle is amber and dashed while monitoring is unavailable, and turns red for an alarm.",
            "The **dashed cyan circle** is how far the boat can swing: the rode stretched taut at the lowest water in the next 24 hours, plus the distance back to the phone amidships. It's the farthest the boat's position (the blue boat) can go, and the suggested alarm circle adds the configured margin (20 ft by default). A manually chosen radius can differ. Remember the **stern reaches half a boat length further** (about 23 ft on Nereus) when checking clearance from rocks, shallows and other boats. The **thick cyan arc** on it is where the wind and current are forecast to put the boat over the next 24 hours.",
        ]),
        .heading("Before you anchor"),
        .text("A panel over the chart shows how much rode to pay out and the **Drop Anchor Here** button. It fades after \(GuideFacts.controlsFadeSeconds) seconds so you can see the chart; **tap the chart** to bring it back. Once you're anchored it goes away, and the radius and anchor controls are on the Anchor tab."),
    ])

    // MARK: Keeping watch

    static let anchoringTutorial = GuideTopic(id: "anchoring-tutorial", title: "Setting an anchor — tutorial", icon: "sailboat", blocks: [
        .text("A practical sequence for anchoring Nereus: choose a suitable spot, prepare the gear, calculate scope, lower and set the anchor, verify the set, then maintain a watch. Read this before the maneuver; during a developing problem, attend to the boat first."),
        .warning("The skipper must adapt the maneuver to the vessel, equipment manuals, bottom, weather and available room. This app estimates position and capacity; it cannot inspect the seabed, measure anchor holding or replace seamanship. Practice in settled conditions with experienced help before relying on the procedure in strong wind."),
        .heading("Terms you will use"),
        .bullets([
            "**Ground tackle**: the whole anchoring system—anchor, connectors, chain or rope, and the hardware that carries the load aboard.",
            "**Rode**: the chain, rope, or chain-and-rope connection between boat and anchor. **Rode out** is the length actually deployed, not the amount in the locker or the amount the calculator recommends.",
            "**Scope**: deployed rode divided by the vertical distance from the seabed to the bow roller or other point where the loaded rode leaves the boat. A 7:1 scope means seven units of rode for each unit of that vertical distance. It is not distance from the anchor divided by depth.",
            "**Set**: the anchor has engaged the bottom and resists a controlled pull. **Dragging** means the anchor is moving across the bottom under load. Being inside an alarm circle is not proof of a good set.",
            "**Catenary**: the curve of hanging chain. As load increases the curve straightens and chain can lift off the bottom. Chain weight is not a substitute for a properly set anchor, suitable scope and shock absorption.",
            "**Snubber / bridle**: an appropriately sized elastic line, or pair of lines, that transfers load to suitable strong points and reduces shock on an all-chain system. A **chain stopper** restrains chain; it does not necessarily provide stretch.",
            "**Swinging room**: the area the whole boat can occupy as wind or current turns it around the anchor. **Lee shore**: a shore toward which the wind would push you if holding were lost. **Under-keel clearance**: water remaining below the deepest part of the boat, with an allowance for waves and uncertainty.",
        ]),
        .heading("1. Choose the anchorage before the drop"),
        .bullets([
            "Use current navigational charts, local information and your sounder. Check depth, bottom, restrictions, cables, pipelines, protected habitat and traffic. The app’s chart is supplementary; an unmarked hazard can still exist.",
            "Consider the strongest expected gusts, wave exposure, overnight changes, tidal flow and a possible reversal of wind or current. Identify a more sheltered alternative and a safe route out before conditions deteriorate.",
            "Allow enough water at the lowest expected level for draft, wave motion and a margin. Allow enough rode at the highest expected level. In Port Lavaca and other shallow bays, compare predicted tide with actual water levels; weather can change the water independently of the tide prediction.",
            "Plan clearance for the stern and the full swing, not just the phone or bow. Other vessels may have different rode lengths and may swing differently. Leave room to recover the anchor or maneuver if a neighbor drags.",
        ]),
        .heading("2. Prepare boat, crew and equipment"),
        .bullets([
            "Agree on helm and bow duties, hand signals or radio communication, and a stop signal. Use appropriate flotation and secure footing. Keep children, loose clothing, fingers and feet away from moving chain, the windlass and line bights.",
            "Inspect anchor, connectors, rode, snubber, chafe protection and attachment points. Know your rode markings, usable length and how the bitter end is secured. Follow the installed equipment manuals; do not improvise a release under load.",
            "Prepare the engine and a clear maneuvering route. Check windlass power and controls before approaching the drop. Do not let a phone task distract either operator during the maneuver.",
            "In **Settings → Boat Profile**, verify the actual anchor, rode type and inventory, boat dimensions and snubber. For real monitoring use **Settings → Testing → Position source → iPhone GPS**, never Simulator.",
        ]),
        .heading("3. Work out depth and scope"),
        .text("First establish what the sounder displays: below the transducer, below the keel, or below the surface. The app’s **Water depth below surface** needs surface-to-bottom depth. Convert the sounder reading using its configured offset; do not add draft twice. Then add the bow roller height above the surface when calculating scope."),
        .formula("Example only — lengths in feet\nWater depth now                  14\nExpected rise before leaving     +2\nDepth at highest water           16\nBow roller above water           +6\nSeabed-to-roller height           22\n\n5:1 scope: 5 × 22 = 110 ft rode\n7:1 scope: 7 × 22 = 154 ft rode\n\nUse the same units throughout."),
        .text("These ratios illustrate the calculation, not a recommendation for every anchorage. Select scope using your anchor manufacturer’s instructions, anticipated conditions, bottom and available swing room. More scope often lowers the pull angle, but cannot fix a fouled anchor or unsuitable ground. If the scope you need will not fit safely, choose another spot rather than shortening it just to fit."),
        .tip("Recalculate after a tide change or a rode adjustment. More water reduces scope with the same rode out; less water can allow a larger horizontal swing. More rode requires a fresh check of neighbors, hazards and alarm radius."),
        .heading("4. Lower the anchor and lay out the rode"),
        .bullets([
            "Approach the intended drop under control, normally into the dominant wind or current. Reduce movement over the ground before lowering; being pointed into the wind alone does not mean the boat has stopped.",
            "Lower the anchor under control to the seabed. As the boat falls back, pay out rode progressively so it lays away from the anchor rather than piling on top. Use only the engine movement necessary to control the boat; keep the rode clear of propellers.",
            "Avoid a sudden stop against a short length of chain. Keep communication between bow and helm, monitor how much is out, and pause the maneuver if anything fouls or the vessel is no longer where intended.",
            "Record the actual anchor drop location. If someone can safely operate the app as the anchor goes down, choose **Anchor going down now**. The app estimates the bow position from the phone; check the resulting mark. If everyone is occupied, concentrate on the boat and enter the position afterward.",
        ]),
        .heading("5. Set the anchor and verify it"),
        .text("Once sufficient rode is deployed, transfer the load to suitable rated hardware as specified by the equipment manufacturer. Apply a gradual, controlled setting load using the vessel’s established procedure. Do not shock-load the system or use an arbitrary engine RPM from a generic guide; thrust and hardware limits differ between boats."),
        .bullets([
            "Watch fixed shore transits or bearings, radar ranges where available, and the plotter track as load builds. Initial movement while the anchor embeds is different from continuing movement after the set should be established. Look for position stabilizing under load.",
            "If the boat continues falling back, treat the set as unconfirmed. Maintain control; recover and inspect for fouling, then reset in suitable ground or choose another location. Do not declare success because the app’s icon is green.",
            "Fit and adjust the snubber or bridle and chafe protection according to the vessel’s procedure. The windlass should not be the sole attachment carrying anchoring loads. Keep clear of loaded lines and fittings; check from a safe position.",
            "After returning to the normal anchored configuration, observe the boat again. Record baseline bearings, depth, position and nearby hazards, and note an escape route. A brief setting check cannot prove the anchor will withstand every later gust or reversal.",
        ]),
        .heading("6. Finish setting up Anchor Watch"),
        .bullets([
            "If entering the anchor after falling back, choose **Boat has settled on the rode** only when that describes the boat. Its upwind placement is an estimate; current, slack rode and changing wind can make it wrong. Use a known drop position to correct the mark on the chart when available.",
            "Confirm **Rode out** as the length actually paid out. If you entered an intended length at the drop and then deployed a different amount, update it on the Anchor tab. Changing a recommendation does not deploy or recover chain.",
            "If the app says **Circle alarm OFF** or asks you to place the anchor, resolve the location before relying on the circle alarm. Do not wait for an automatic swing estimate as your only watch. Place the mark using the best available evidence, then verify it.",
            "Choose an **Alarm radius** that accommodates the phone’s expected normal movement and GPS uncertainty yet leaves useful warning before danger. The phone is assumed amidships; the stern can extend beyond its circle. If normal swing and safe warning cannot both fit, reconsider the anchorage.",
            "Check **Alarm readiness**, location permissions, current GPS quality, phone power, volume and audio output. Run a siren test, including with the phone locked in its intended location. Use an independent plotter alarm when available and keep a human watch appropriate to conditions.",
        ]),
        .warning("Do not move the anchor mark to the boat or enlarge the circle merely to stop an unexplained alarm. That can hide genuine dragging. Establish what happened first; correct a proven setup error or deliberately reset after re-anchoring."),
        .heading("7. What to watch after setting"),
        .bullets([
            "**Position trend**: an arc around a stable center can be normal swing. Persistent movement away from the anchor, a shifting track center, or changing fixed references needs investigation. Slow dragging may occur entirely inside a large alarm circle.",
            "**Wind and current**: compare actual gusts and direction with the forecast. A significant reversal can load the anchor from a new direction; watch its response rather than assuming it will reset. Nearby station readings may not match your anchorage.",
            "**Water and clearance**: check the sounder, under-keel margin, high-water scope, low-water swing, and neighboring boats. High or low tide is not necessarily the time of current slack.",
            "**Gear and readiness**: inspect snubber condition and chafe when safe, watch for shock loading, and check phone power, GPS freshness and audible alarm output. Increase watchkeeping when conditions worsen or evidence conflicts.",
        ]),
        .heading("8. If the app shows a modeled capacity warning"),
        .text("**Holding** in the monitoring panel means the app has not detected a position alarm condition. **Exceeds modeled limits** is a separate planning assessment. A green monitoring panel can coexist with a red capacity warning; neither is a measurement of how well the anchor is buried."),
        .text("For the example **37 kt gusts; 1,379 lbf estimated pull; 1,100 lbf rough holding; estimated limit 27 kt**, the model predicts inadequate margin for the entered setup. The load and holding figures are estimates, not load-cell readings. The gust threshold can be set by either estimated anchor holding with a safety allowance or complete chain lift-off; chain lift-off alone does not mean dragging."),
        .bullets([
            "First check real position and available clearance. Maintain an active watch and have propulsion ready while you assess the situation. Actual movement toward a hazard takes priority over adjusting model inputs.",
            "Verify anchor, bottom, deployed rode, depth reference, bow height, current, waves and windage. Do not change inputs solely to obtain a green result. A bottom label is an assumption unless supported by local evidence.",
            "Consider the whole anchorage: exposure, holding, swing room and a safe alternative. Do not automatically add chain. With 296 ft out in about 14 ft of water, first verify the entries and assess the actual limitations; extra chain is not a guaranteed cure and increases swing room needed.",
            "A forecast warning’s clock time identifies a modeled forecast hour, not a promise of safety until then. If comparable gusts are already occurring, assess present conditions now. **Set gust warning to…** changes a warning threshold only; it does not strengthen the anchoring system.",
        ]),
        .heading("9. If the circle alarm sounds or dragging is suspected"),
        .bullets([
            "Attend the helm, alert the crew, assess immediate clearance and prepare or start propulsion as circumstances require. Do not spend the first minutes debugging the phone while drifting toward danger.",
            "Cross-check the sounder, plotter/radar, fixed references, distance trend and GPS quality. One scattered fix may be GPS error; a consistent movement trend is more concerning. If the evidence is uncertain and clearance is small, act conservatively.",
            "If dragging is confirmed, or collision/grounding is approaching, use controlled propulsion as appropriate to prevent danger. Keep the rode clear of the propeller and avoid driving over it. A helm operator should maintain control while the crew follows the vessel’s recovery procedure.",
            "When safe, recover and inspect the anchor and reset with sufficient room, or move to a safer anchorage. Do not raise the anchor before the vessel can be controlled, or allow the windlass to haul the boat against heavy wind or current.",
            "Request assistance early if you cannot control the situation. In grave and imminent danger, use your marine distress procedure, including VHF channel 16 and DSC where fitted and configured. Give vessel name, position, nature of danger and persons aboard; do not wait for the app to declare an emergency.",
        ]),
        .tip("**Silence** stops the current siren; it does not establish that the problem is solved. **Raise Anchor** and **Retrieve Anchor** end circle monitoring. Use those controls deliberately as part of leaving or re-anchoring, not as an acknowledgement of a warning."),
        .heading("10. Other circumstances and useful responses"),
        .bullets([
            "**Wind rising, squall or falling pressure:** reassess exposure, escape route, ground tackle and actual gusts early. Secure loose gear and keep crew ready. Move to shelter while a safe move is still possible rather than relying on a precise modeled failure speed.",
            "**Wind/current reversal:** watch the track and fixed references through the swing, check the new downwind/down-current hazards, and verify that the anchor re-establishes its hold. Other boats may turn at different times.",
            "**Shallow-water warning:** verify actual depth and the sounder offset, remaining tide, draft and wave allowance. Move before clearance becomes critical when safe; more rode does not solve inadequate water under the keel.",
            "**GPS interrupted or alarm readiness degraded:** treat electronic monitoring as unavailable or impaired, keep an independent watch, and restore location, power or sound output. A stale green position is not current evidence of holding.",
            "**No internet or stale forecasts:** GPS circle monitoring can operate without downloaded weather, but forecasts and station advice may be unavailable. Use VHF weather, onboard instruments and other available information; missing warnings are not an all-clear.",
            "**Another boat dragging toward you:** call the crew’s attention, prepare to maneuver and protect your escape route. Your own anchor circle cannot warn reliably about a moving vessel approaching you.",
            "**Repeated snatching, chafe or equipment trouble:** keep people away from loaded fittings. Reassess snubber arrangement and exposure within equipment limits; reduce the risk or relocate before gear fails. Do not improvise a second-anchor arrangement without the appropriate equipment and experience.",
        ]),
        .heading("11. Before settling in for the night"),
        .text("Confirm the set, actual rode, anchor mark, usable alarm radius, low-water clearance, high-water scope, overnight swing room, weather trend, power and siren. Agree who checks conditions and when, and what will trigger getting underway. If the situation calls for a continuous anchor watch, an app is not a substitute for that watch."),
        .text("To reduce advisory clutter use **Settings → Warnings**. **Hide warning banners** changes dashboard presentation; **Silence advisory notifications** stops new weather/barometer notifications. Review retained information through **Alarm ON → Warnings**. Anchor alarms and critical monitoring warnings remain active."),
        .heading("12. Recovering the anchor"),
        .text("Brief the crew, have propulsion and a clear departure route ready, then recover under control. Follow the windlass and anchor manuals: maneuver the vessel toward the anchor rather than pulling the vessel with the windlass. Keep people clear as the anchor breaks out and comes aboard. Stop and reassess a foul or overload rather than forcing it. Secure the anchor independently for passage, end monitoring deliberately, and note holding performance in the Anchorage Log."),
        .heading("Further reading"),
        .text("General guidance was checked against the sources below. Manufacturer instructions are specific to their equipment; use the manuals for the anchor and windlass actually installed aboard Nereus. Tutorial reviewed 16 October 2026. The instructional text is available offline; opening an external source requires a connection."),
        .text("[BoatUS Foundation — anchoring and mooring](https://boatus.org/study-guide/navigation-maneuvering/anchoring-mooring/)"),
        .text("[Rocna — anchor user guide](https://rocna.com/user-guide/) · [Setting and retrieval](https://kb.rocna.com/kb/Setting_and_retrieval)"),
        .text("[Lewmar — V8/V9/V10/V12 manual, anchoring procedures](https://www.lewmar.com/mst_attachment/attachment/click/attachment_id/269/)"),
        .text("[NOAA — water levels and tide/current information](https://tidesandcurrents.noaa.gov/) · [US Coast Guard — marine radio and distress guidance](https://www.navcen.uscg.gov/gmdss-frequently-asked-questions)"),
    ])

    static let settingAnchor = GuideTopic(id: "anchor", title: "Setting and moving the anchor", icon: "arrow.down.to.line", blocks: [
        .heading("Dropping it"),
        .text("Tap **Drop Anchor Here**, confirm the actual rode paid out, and choose when: **Anchor going down now** puts the mark half a boat length ahead of the phone, since the phone is amidships and the anchor goes over the bow. **Boat has settled on the rode** puts it a whole scope distance ahead (your rode out stretched across the bottom, plus half the boat), upwind, since a settled boat lies downwind of its anchor. Either way the app uses the average of the last \(GuideFacts.averagingSeconds) seconds of GPS positions, to reduce sensitivity to a stray fix; it cannot eliminate GPS or heading errors."),
        .text("Which way is \"ahead\"? For **going down**, toward where the bow pointed: the direction you came in on over the last minute, if you moved at least 15 m (about 50 ft); otherwise into the forecast wind, if there's 5 knots or more. For **settled**, into the wind only, since the last minute's movement is the boat falling back. If there's too little wind (under 5 knots) to tell which way a settled anchor lies, the mark could be a whole scope distance out, so **the circle alarm isn't armed until you place and verify the mark or a usable swing fit** becomes available; it may take about 20 minutes or may not succeed: the status reads **Circle alarm OFF** and the chart uses an amber dashed circle. Place the anchor manually to enable monitoring; a reminder sounds after five minutes if it remains unresolved. The GPS and battery alarms still work, and placing the anchor yourself arms it straight away. If it can't tell, it leaves the anchor at the phone and widens the dotted circle instead. A note in the Anchor section of the Anchor tab says which it used."),
        .bullets([
            "If GPS accuracy is worse than about 26 ft, an orange warning appears and the button reads **Drop Anchor Anyway**. Waiting a minute usually helps.",
            "If accuracy is worse than about 165 ft, the button is disabled. Move the phone near a window, or outside.",
        ]),
        .heading("Correcting it later"),
        .bullets([
            "**Long-press on or near the anchor symbol, then drag** it to a new spot; the chart holds still while you do. A **nudge pad** of arrows appears on the chart for fine-tuning (5 ft, or 1 m, a tap); it's also under **Fine-tune** on the Anchor tab, and its ✕ hides it. While you drag, a yellow line runs from the boat to it, labelled with the distance and bearing from the boat (for example New 225 ft · NE 054°), and a white dashed line from the original drop spot, labelled with how far it has moved. The lines stay up and follow the boat. Tap the **✕** on a label to close that line, so you can keep the boat's distance and bearing showing after the moved distance has gone. **Slide a label** with your finger to move it somewhere readable; it keeps its place beside its line. The original drop spot keeps a faded anchor mark until you raise the anchor. **Long-press it** to remove it and make the current spot the official one: the next move measures from there and leaves its own faded mark.",
            "**Move Anchor** on the Anchor tab: the app switches to Watch, then tap the chart where the anchor should be (or **Cancel**).",
            "**Anchor → Boat** (also on the Anchor tab) moves the anchor to the boat's bow (averaged position, moved forward along the rode).",
        ]),
        .text("Moving the anchor resets Max distance and resolves pending placement. It does not prove that an alarm was false or cure dragging. Correct the mark only from evidence, then reassess the circle and the boat’s position."),
        .heading("Finding the anchor from the swing"),
        .text("After about 20 minutes at anchor, the app fits a circle to the edge of your swing to estimate the anchor position from the available movement. A usable fit is not guaranteed in that time. When a fit is available, it shows a purple ring on the chart and a line in the Anchor section of the Anchor tab: either the swing agrees with your mark, or it says how far off the mark is with **Move there** to correct it. The **first** fit after a drop (within 90 minutes) moves the mark there by itself if it's clearly off, and says so in a purple banner with **Undo**. It only does this once, and never if you've moved the anchor yourself: after that a moving swing is a sign of dragging, so it raises the drag warning rather than moving the circle. You can also **long-press the purple ring** on the chart, or tap it and choose **Move anchor here**, to move the anchor there. See **How Anchoring works it out** for the details."),
        .heading("Raising it"),
        .text("**Raise**, on the Anchor tab or by tapping the status, ends the watch: it clears the anchor, the track and any alarm, and switches the audio and lock-screen card off. Either asks first, and offers **Retrieve Anchor** as well."),
        .heading("Retrieving it"),
        .text("**Retrieve Anchor** ends the watch the same way, then opens a screen for the helm: a big arrow from the **bow** to the anchor, how far it is, and what to do: **Dead ahead**, **Steer 15° to starboard**, **Behind you: turn round**. The bow is taken as half a boat length ahead of the phone."),
        .bullets([
            "Moving at half a knot or more, the arrow is relative to your course over the ground: straight up means steer straight on.",
            "Slower than that, GPS can't tell which way you're heading, so the arrow points to the anchor with north up and the bearing is given (Anchor lies NE, 045°).",
            "Within about half the depth (at least 13 ft), the display turns green: **Over the anchor**. This is a proximity estimate, not confirmation that the rode is vertical; verify aboard and follow your equipment’s recovery procedure.",
            "**Anchor's up** closes it. The Apple Watch shows the distance and steering too.",
        ]),
        .tip("The anchor and radius are saved for restoration after relaunch, but monitoring does not continue while the phone is off or the app is force-quit. Recheck position and alarm readiness after reopening. Saved information is not evidence of an uninterrupted watch."),
    ])

    static let alarmCircle = GuideTopic(id: "circle", title: "The alarm circle, rode and scope", icon: "circle.dashed", blocks: [
        .heading("Choosing the radius"),
        .text("Drag the **Alarm radius** slider on the **Anchor** tab, under Rode out. The circle should be big enough for the boat to swing freely on its rode, plus some room for GPS error."),
        .heading("The Water tab"),
        .bullets([
            "Enter the **water depth** at the anchorage with the − and + buttons, or type it.",
            "Add the **tide**: the extra depth you expect (see Tides). The rode has to cover high water.",
            "Pick a **scope ratio**: 3:1, 5:1, 7:1 or 10:1. These are calculator choices, not assurances of suitability. Follow your equipment guidance, conditions and available swing room; see the anchoring tutorial.",
            "**Rode to pay out** = ratio × (depth + tide + bow height).",
            "**Suggested alarm radius** = the **scope distance** (how far your rode out reaches across the bottom when taut, at the lowest water in the next 24 hours), plus half the boat's length (the phone is assumed amidships), plus the configured margin (**20 ft** by default). It's set automatically when you drop the anchor, and follows if you change **Rode out**, until you move the radius slider yourself; **Use suggested radius** goes back to it.",
        ]),
        .text("Bow height and boat length live in **Settings → Boat Profile**, and also in the **Scope calculator** (the link in the Anchor section of the Anchor tab) along with the safety margin. **Radius follows rode and depth** on Anchor enables automatic radius updates; a manual radius stays fixed until you re-enable following or use the suggestion. The default boat length is 47 ft; enter the actual length and configuration you use. The phone is assumed amidships."),
        .text("The scope screens warn when recommended rode exceeds the configured inventory. Recommendations and radius changes do not change confirmed deployed rode. Update **Rode out** explicitly after actually paying out or recovering rode."),
        .tip("If the circle is too small for your GPS accuracy, the Watch check says so. A circle less than about 2½ times the GPS error invites false alarms."),
    ])

    static let alarms = GuideTopic(id: "alarms", title: "Alarms and Silence", icon: "bell.badge", blocks: [
        .heading("When the alarm sounds"),
        .text("The app attempts to play a two-tone siren using playback audio, including with the silent switch on. Volume, the selected audio route and audio failures still matter; test the actual output. The phone provides haptics, an allowed notification can appear, and a red **Silence** banner appears along the lower screen edge. Critical readiness problems are shown separately."),
        .heading("What triggers it"),
        .bullets([
            "**Boat left the circle**: \(GuideFacts.confirmFixes) GPS readings in a row beyond the radius. To avoid false alarms, a reading must be outside by more than its own error (up to \(GuideFacts.discountCapPercent)% of the radius). Coming back inside restarts the count.",
            "**GPS signal lost**: no position for \(GuideFacts.gpsLostSeconds) seconds.",
            "**GPS too inaccurate**: positions keep arriving but none is usable for \(GuideFacts.gpsPoorSeconds) seconds.",
            "**Anchor position unresolved**: a reminder after five minutes if settled placement remains unconfirmed; place and verify the anchor mark to enable the circle alarm.",
            "**Low battery**: \(GuideFacts.batteryAlarmPercent)% or less and not charging. You also get a quiet notice at \(GuideFacts.batteryNoticePercent)%, and another if the charger is unplugged.",
        ]),
        .heading("Anchor dragging warning"),
        .text("Separately from the siren, the app watches where the swing says the anchor is. If it moves steadily one way, a **red banner** says the anchor appears to be dragging, and a red arrow on the chart shows how far and which way. It can come well before the boat leaves the circle. It's a warning, not the siren: check your position and be ready to re-anchor. See **How Anchoring works it out** for how it decides."),
        .heading("Silence"),
        .text("**Silence** stops the siren. The same alarm can sound again after \(GuideFacts.snoozeSeconds) seconds if the problem is still there (\(GuideFacts.batterySnoozeMinutes) minutes for the battery alarm). Silencing one kind of alarm doesn't silence the others, and a higher-priority position alarm can take over from a battery or GPS alarm."),
        .warning("Silence doesn't fix anything. If the boat really has dragged, deal with it, then check the circle and anchor position."),
    ])

    static let watchCheck = GuideTopic(id: "watchcheck", title: "Watch check and test siren", icon: "checklist", blocks: [
        .text("Orange or red readiness information means something needs attention. Open **Alarm ON → Warnings → Alarm readiness**, or **Settings → Testing → Watch check and test siren**, for the full list."),
        .heading("What it checks"),
        .bullets([
            "**Siren availability**: audio setup or restart failures are critical until startup succeeds; keep a separate watch and test after recovery.",
            "**Volume**: warns under 50%, and more strongly under 20%.",
            "**Sound output**: warns if the siren would play through AirPods or a Bluetooth speaker instead of the phone.",
            "**Battery**: warns under \(GuideFacts.batteryWarnPercent)% when not charging.",
            "**Notifications** and **Location: Always**: warns if either is off.",
            "**Lock-screen status**: says if the Live Activity is off or couldn't start.",
            "**GPS accuracy** and **alarm circle size** compared with that accuracy.",
        ]),
        .heading("Testing the siren"),
        .bullets([
            "**Test siren now** plays the alarm for 4 seconds.",
            "**Test siren in 15 seconds** waits, so you can lock the phone or switch to another app first and check whether it sounds from the background in that setup. The lock-screen card turns red and says it's a test.",
        ]),
        .tip("With an anchor set, the app keeps its audio quietly running so the siren can start instantly even when the phone is locked. It plays over music or a chart app without pausing it."),
    ])

    static let lockScreen = GuideTopic(id: "lockscreen", title: "Lock screen and Dynamic Island", icon: "lock.iphone", blocks: [
        .text("While an anchor is set, a card on the lock screen and a pill in the Dynamic Island show the distance from the anchor, the circle size and a progress bar."),
        .bullets([
            "Status follows the phone’s monitoring/readiness assessment, including circle ON/OFF, GPS interruption and critical problems. Green is not a statement of modeled holding capacity. Red identifies an active alarm.",
            "If the app stops updating for \(GuideFacts.liveActivityStaleMinutes) minutes, the card says **Not updating. Open Anchor Watch.** Treat that as a warning.",
        ]),
        .heading("If it doesn't appear"),
        .bullets([
            "It starts when you **drop the anchor with the app open**. If you reopen the app with an anchor already set, check the Watch check.",
            "Turn it on in the iPhone's **Settings → Anchor Watch → Live Activities**.",
            "If you swipe the card away, it comes back when you next open the app.",
        ]),
    ])

    // MARK: Charts and weather

    static let appleWatch = GuideTopic(id: "applewatch", title: "Apple Watch", icon: "applewatch", blocks: [
        .text("Anchor Watch installs on a paired Apple Watch along with the phone app (if it doesn't, turn it on in the iPhone's Watch app under Available Apps)."),
        .heading("What it shows"),
        .text("The same circle alarm and readiness status as the phone (ON, OFF, monitoring interrupted or a warning), the distance from the anchor, the alarm radius, which way the anchor lies, the wind and when it last heard from the phone. The phone sends an update when anything changes, and at least every 30 seconds while it's within range; the line turns orange after two minutes without one."),
        .heading("Chart"),
        .text("**Turn the crown or swipe up** for the chart: the anchor in the middle, the alarm circle, the recent track and the boat, north up. It zooms out if the boat goes outside the circle. The track updates about every 10 seconds."),
        .heading("Night colours"),
        .text("When the phone goes into **Night mode**, the watch turns red on black too, and back again when you leave it. The **moon** button on either watch screen (at the bottom of the status, beside the distance on the chart) switches it there; a **sun** turns it off."),
        .heading("Alarms"),
        .text("When the phone's alarm goes off, the watch turns red, shows what's wrong and taps your wrist every two seconds while the watch app is open. **Silence** on the watch silences the phone too."),
        .warning("The phone does the watching and sounds the siren. The watch only shows what the phone sends: keep the phone aboard, charged and within Bluetooth range."),
    ])

    static let charts = GuideTopic(id: "charts", title: "Charts and zooming", icon: "map", blocks: [
        .text("Tap the **map** button to choose a chart:"),
        .bullets([
            "**OpenSeaMap**: OpenStreetMap base tiles with OpenSeaMap seamarks. Coverage and detail vary by area. Cached tiles follow provider expiry rules; viewing an area once does not guarantee offline availability.",
            "**NOAA Charts (US)**: NOAA chart rendering with soundings and contours where the service has coverage. It may be blank outside coverage; it is not a complete offline navigation product.",
            "**Apple Maps**: the standard iPhone map.",
            "**Satellite + Seamarks**: satellite photos with the seamarks.",
        ]),
        .text("Zoom with **+** and **−**, or pinch. On the OpenSeaMap and NOAA charts, zooming in stops at the closest level that has map detail."),
        .warning("These charts are a backdrop for watching the anchor, not for navigation. Use your official charts, such as TZ iBoat or Navionics, for that."),
    ])

    static let wind = GuideTopic(id: "wind", title: "Wind overlay and conditions", icon: "wind", blocks: [
        .heading("Chart overlay"),
        .text("Tap the **wind** button to toggle forecast arrows. Arrows indicate where wind blows toward; the number is speed in knots. Tap for direction and gusts. The slider selects up to 48 hours ahead. Forecast samples advance with time; expired or unavailable samples are removed rather than shown as current."),
        .bullets([
            "Colors: grey under 5, green 5–10, yellow 10–15, orange 15–20, red 20–25, purple over 25.",
            "**Blue numbered badges** identify nearby observation stations. Check the measurement time; a nearby reading is not a measurement aboard your boat.",
            "Panning requests a forecast grid for the visible area. Requests are debounced and cached, and refreshes can fail offline.",
        ]),
        .heading("Weather tab"),
        .text("Tap the Wind dashboard tile or open **Weather** for forecast wind, direction, gusts, the forecast chart, wind warnings, barometer and station details. **Show these stations on the chart** returns to Watch and frames them. Expand the forecast-status disclosure for provider ages, coverage and assumptions; **Retry all environmental data** retries wind, tides, currents, observations and alerts."),
        .heading("Warning controls"),
        .text("Forecast/observed gust warnings use **Settings → Gust Warning** (default \(GuideFacts.gustDefaultKnots) knots). Wind shifts of \(GuideFacts.windShiftDegrees)° or more are also assessed. These advisories do not sound the anchor siren, and the overlay does not need to be on. **Hide warning banners** suppresses dashboard advisories; **Alarm ON → Warnings** retains access. The Anchor tab’s modeled capacity threshold is calculated separately from your user-selected gust warning."),
        .heading("Official alerts and partial data"),
        .text("Active US National Weather Service alerts are available from **Warnings → Weather alerts** and advisory notices when shown. Serious/marine alerts can send a new-alert notification unless **Silence advisory notifications** is enabled. That setting also suppresses new barometer notifications; it does not mute the anchor siren or battery safety notices."),
        .text("NOAA and Canadian observations are collected independently, so available Canadian readings can survive a NOAA outage. Partial coverage and refresh errors remain visible in provider details. Headline gust advice uses fresh observations and expired weather alerts are filtered; retained station detail must still be checked for age."),
    ])

    static let tides = GuideTopic(id: "tides", title: "Tides, depth and current", icon: "water.waves", blocks: [
        .heading("Confirm measured depth"),
        .text("On **Water**, enter surface-to-seabed depth, correcting any sounder keel/transducer offset first. Use **Confirm this depth as a new sounder reading** to establish a new measurement time even when the number is unchanged. The reference text identifies the measured versus estimated depth. Where compatible tide data covers the measurement, later depths use the change in predicted level rather than adding the full tide height to your reading."),
        .heading("Station coverage"),
        .text("The app selects a NOAA or Canadian Hydrographic Service prediction station within 25 km. If none qualifies, tide adjustment is unavailable. Nearest does not mean the same tide regime: verify suitability for your anchorage. Cached predictions show their age; provider details expose missing or unusable coverage."),
        .bullets([
            "**Right now (estimated)** is the station’s predicted height above its chart datum, not measured water depth under your boat. High/Low rows are predictions at that station.",
            "Choose **Cover the next** 6, 12 or 24 hours, then **Use tide data** to copy the expected rise. You can also enter an expected rise manually. Avoid counting a rise twice when working from a depth already referenced to high water.",
            "The depth outlook separates shallow intervals when a safe sample intervenes. Warnings depend on draft, the depth reference and available forecast coverage; absence of a warning is not a sounding.",
        ]),
        .heading("Current"),
        .text("The **Current** section shows NOAA station predictions, slacks and flood/ebb peaks where available. Estimated anchorage speed is station speed multiplied by the selected 100%, 50% or 25% share. This scaling is an assumption, not a current measurement. Advice uses predicted current slack when available; high/low water alone does not establish reversal time."),
        .warning("Wind, pressure and local flow can make actual water levels and currents differ from predictions, especially in shallow bays. Check the sounder and local information, allow clearance, and do not use station proximity as proof of accurate conditions aboard."),
    ])

    static let canada = GuideTopic(id: "canada", title: "Canadian waters", icon: "globe.americas", blocks: [
        .bullets([
            "**Local monitoring**: GPS circle monitoring and readiness checks do not depend on US weather coverage. Environmental coverage and freshness still vary by provider and location.",
            "**Tides**: NOAA and Canadian Hydrographic Service prediction stations are considered, subject to the 25 km coverage limit and local suitability checks.",
            "**Weather stations**: Environment Canada's stations join NOAA's, and the nearest ones are used.",
            "**Charts**: the NOAA layer is US only. OpenSeaMap works as a backdrop.",
            "**Weather alerts**: only US alerts are covered for now. For Canadian marine warnings, use VHF weather or Environment Canada.",
        ]),
        .tip("Cell data can be patchy in the islands and may cost roaming charges. Load and inspect the information you need while connected, but do not assume cached charts will remain available. Keep independent navigational charts and check tide data age."),
    ])

    // MARK: Reference

    static let settings = GuideTopic(id: "settings", title: "Settings", icon: "gearshape", blocks: [
        .bullets([
            "**User Guide**: this guide.",
            "**Boat Profile**: the boat's size, windage, anchor, rode and snubber. It feeds the scope, holding and wind-load maths. Several fields begin with assumed defaults. Verify them; an unchanged default is not a measured input.",
            "**Gust Warning**: the gust limit for the wind warnings.",
            "**Warnings**: hide advisory dashboard banners or silence new weather/barometer notifications. **Review warnings**, also under **Alarm ON → Warnings**, retains access to hidden items. Anchor alarms and critical monitoring warnings stay active.",
            "**Track**: draw the track under way, not only at anchor, and keep the way in after you drop the anchor. Raise clears it. With Track on, the GPS runs at full accuracy whenever the app is open.",
            "**Saving battery**: with no anchor set, the screen sleeps as usual and, unless Track is on, the GPS eases off a little. Both go back to full as soon as you open the drop sheet, anchor or retrieve; while anchored the screen stays on.",
            "**Fade Buttons**: fade the row of buttons under the chart when idle. Tap the chart to bring them back.",
            "**Units**: Metric or Feet; the choice is remembered across relaunches.",
        ]),
        .heading("Version and saved information"),
        .text("**Settings → About Anchor Watch** shows the installed version, build number and environment. Use the build number when reporting a problem. The Anchorage Log reports save/load failures and offers retry. If recovered from backup, review it because the latest changes may be missing. Keep the app open and retry an unsaved log; an edit appearing on screen does not guarantee it reached storage."),
        .heading("Testing"),
        .bullets([
            "**Position source**: **iPhone GPS** for real use. **Simulator** moves a pretend boat around Roche Harbor or Sidney for practice, and the top of the screen says Simulated GPS whenever it's on.",
            "**Simulator options**: start location, scenario (swinging, wind shift, dragging anchor, GPS dropout, wide swing, slow drag) and speed up to 60×. Sped up, the swing fit's waits shrink too, so **Wide swing** at 60× shows the anchor estimate about 22 seconds after you drop, and **Slow drag** shows the dragging warning a little later. In the dragging scenarios the alarm comes back every minute after Silence; tap **Raise** to end it.",
            "**GPS receiver**: with an external GPS such as a Garmin GLO 2 connected, live readings from it and from the iPhone.",
            "**GPS Quality**: recent positions scattered round their average, accuracy over time, and live numbers. Use it to compare places to put an external receiver.",
            "**Watch check and test siren**: see that topic.",
        ]),
        .tip("Changing the simulator's start location raises any anchor, since the old anchor would be a long way from the new boat."),
    ])

    static let troubleshooting = GuideTopic(id: "trouble", title: "Troubleshooting", icon: "wrench.and.screwdriver", blocks: [
        .heading("The GPS reading is poor or slow"),
        .bullets([
            "Indoors, GPS can be slow and off by 50 ft or more. A window, hatch or open deck is much better.",
            "A metal roof or cabin top blocks the signal. A GPS antenna outside the cabin is the real cure.",
            "Check **Settings → Privacy & Security → Location Services → Anchor Watch**: **Always** and **Precise Location** on.",
        ]),
        .heading("False alarms"),
        .bullets([
            "First check for actual dragging, normal swing, GPS error or a misplaced anchor mark using independent position evidence.",
            "After identifying a setup error, correct the mark or radius deliberately. Check normal swing and available clearance; do not enlarge the circle or use **Anchor → Boat** just to silence an unexplained alarm.",
        ]),
        .heading("The siren is quiet or silent"),
        .bullets([
            "Turn the volume up. The Watch check shows it.",
            "Disconnect Bluetooth speakers and AirPods.",
            "Check **Alarm readiness** for an audio failure. After interruption or media reset, the app attempts to rebuild/restart audio; run a new siren test and keep an independent watch until output is confirmed.",
        ]),
        .heading("Other things to check overnight"),
        .bullets([
            "Plug the phone in. Turn **Low Power Mode** off, since it can slow background checks.",
            "Don't force-quit the app; the iPhone can't keep watching a closed app.",
        ]),
        .heading("The app won't open"),
        .text("Apps installed with a free Apple ID stop opening after 7 days. Ask for it to be reinstalled while the phone is plugged in to the Mac."),
    ])

    static let dataSources = GuideTopic(id: "sources", title: "Where the data comes from", icon: "antenna.radiowaves.left.and.right", blocks: [
        .bullets([
            "**Maps**: © OpenStreetMap contributors; seamarks from OpenSeaMap; Apple Maps.",
            "**US charts, tides and stations**: NOAA (charts, CO-OPS tide predictions, National Data Buoy Center observations).",
            "**US weather alerts**: National Weather Service.",
            "**Wind forecasts**: Open-Meteo.",
            "**Canadian tides**: Canadian Hydrographic Service. **Canadian observations**: Environment and Climate Change Canada.",
        ]),
        .text("Environmental requests start automatically once a location is available. Open-Meteo and NWS requests may contain precise coordinates; map providers receive the viewed area. Public tide and observation station lists are selected locally. When a stay is logged, Apple reverse geocoding receives anchor coordinates to suggest a name. Saved app data stays on your devices, monitoring information is sent to a paired Watch and enabled Live Activities, and device backups may contain app data. The developer does not receive your log."),
    ])

    static let safety = GuideTopic(id: "safety", title: "Important limits", icon: "exclamationmark.shield", blocks: [
        .warning("Anchor Watch is an aid, not a substitute for a proper anchor watch."),
        .bullets([
            "GPS can be wrong, or lost. The phone can run out of battery, be silenced, or be closed. Treat the alarm as a backup to your own judgement and your anchor.",
            "Forecasts, tide predictions and weather observations can be wrong or out of date. They need an internet connection.",
            "Charts shown here are not for navigation.",
            "The alarm only knows where the phone is. A boat that swings wide in a gust may leave the circle without dragging, so size the circle accordingly.",
            "Keep VHF weather and your normal safety routines.",
        ]),
    ])
}

// MARK: Screens

/// The guide's table of contents.
struct UserGuideView: View {
    var body: some View {
        List {
            ForEach(UserGuideContent.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.topics) { topic in
                        // A direct destination, like the other links in Settings. The value-based style
                        // left this list on screen on top of the topic when used inside a sheet.
                        NavigationLink {
                            GuideTopicView(topic: topic)
                        } label: {
                            Label(topic.title, systemImage: topic.icon)
                        }
                    }
                }
            }
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GuideTopicView: View {
    let topic: GuideTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func view(for block: GuideTopic.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text).font(.headline).padding(.top, 6)
        case .text(let text):
            Text(LocalizedStringKey(text)).font(.body)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.body.bold())
                        Text(LocalizedStringKey(item)).font(.body)
                    }
                }
            }
        case .tip(let text):
            callout(text, icon: "lightbulb.fill", color: .blue)
        case .warning(let text):
            callout(text, icon: "exclamationmark.triangle.fill", color: .orange)
        case .formula(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.footnote, design: .monospaced)).fixedSize().textSelection(.enabled)
                    .padding(12)
            }
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func callout(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(LocalizedStringKey(text)).font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One page to scan: what each part of the app does, and what it works out. The User Guide has the detail.
struct QuickGuideView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private let watch = [
        Item(title: "Status", text: "Circle alarm ON or OFF, interrupted GPS, readiness problems or an alarm. This status is shared with the Watch and lock screen. Tap it to drop or raise the anchor."),
        Item(title: "Tiles", text: "Wind and direction, depth at high tide, scope, anchor, tide, and distance from the anchor."),
        Item(title: "Next 24 hours", text: "The next potential issue in available forecast inputs. Tap for details; hidden advisories remain under Alarm ON → Warnings. Missing data is not an all-clear."),
        Item(title: "Chart", text: "Alarm circle (green), swing circle and forecast swing arc (cyan), track, anchor, original drop mark, and the swing's estimate of the anchor (purple)."),
        Item(title: "Hazards", text: "Long-press empty chart to mark a rock, shoal, dock or boat; long-press one and drag to move it. The Tide tile becomes Clearance: the gap from your stern's swing to the nearest one. Tap a hazard to edit or remove it."),
        Item(title: "Moving the anchor", text: "Long-press the anchor and drag. Yellow line: distance and bearing from the boat. White line: how far it moved. Tap ✕ to close a label, slide it to move it. Arrows fine-tune 5 ft a tap."),
        Item(title: "Barometer", text: "A fall of 3 hPa in 3 hours suggests wind risk; 6 hPa is labeled gale risk. New notifications can be silenced in Settings → Warnings; this is not a weather diagnosis."),
        Item(title: "Alarms", text: "Outside the circle, GPS lost/poor, unresolved anchor setup and low battery. Check readiness, volume and audio route, and run a siren test; advisory silence does not mute these alarms."),
        Item(title: "Night mode", text: "The moon button: a dim black and red screen with the distance and a small radar. Tap to exit."),
        Item(title: "Apple Watch", text: "Status, distance, radius and wind on the wrist; turn the crown for the anchor, circle and track. Taps your wrist on an alarm, and Silence works from there. Red at night, with the phone or the moon button."),
    ]

    private let tabs = [
        Item(title: "Anchor", text: "Monitoring status, separate planning capacity and estimated gust threshold, the rode at Low tide/Now/High tide, deployed rode, depth, radius following and anchor controls."),
        Item(title: "Water", text: "Depth now, a 24-hour depth chart against your keel, warnings for thin water or short scope, and tidal current."),
        Item(title: "Weather", text: "24 hours of wind and gusts against the gust your setup holds, wind changes, the barometer, and nearby station readings."),
        Item(title: "Settings", text: "Boat profile, log, warning visibility and notifications, gust threshold, remembered units, About version/build, guides and Testing (GPS source, receiver quality, simulator)."),
    ]

    private let dropping = [
        Item(title: "Drop", text: "Confirm actual deployed rode and whether the anchor is going down now or the boat has settled. Verify the mark and resolve Circle alarm OFF before relying on position alarms."),
        Item(title: "Radius", text: "Suggested from actual rode reach at low water, half the boat and configured margin (20 ft default). Verify safe clearance; manually changing radius stops automatic following."),
        Item(title: "Swing fit", text: "A sufficient swing can produce an estimated center, often after about 20 minutes. A qualifying first fit may correct the mark once early in the session; success and accuracy are not guaranteed."),
        Item(title: "Retrieve", text: "Raise offers Retrieve Anchor: an arrow and distance from the bow to the anchor, and which way to steer, until it's over the anchor."),
        Item(title: "Log", text: "Stays of ten minutes or more are logged when raised; check any save error. Anchor near a logged spot and it offers that visit's rode and bottom. Swipe a stay left to delete or lock it."),
        Item(title: "Drag watch", text: "A steady move away, or the swing itself shifting, raises a warning before the alarm."),
    ]

    private let maths = [
        Item(title: "Where you are", text: "Distance and bearing to the anchor; averaged GPS at the drop; the anchor placed ahead of the bow; outside the circle only by more than the GPS error."),
        Item(title: "Swing and drag", text: "A circle fitted to the edge of the swing finds the anchor; a line through successive fits, or a steadily growing distance, shows dragging."),
        Item(title: "Rode and scope", text: "Rode to pay out = scope × (depth + tide + bow height). Reach when taut = √(rode² − (depth + bow)²). Live scope as the tide moves."),
        Item(title: "Loads", text: "Wind on the front or side windage, current on the hull, extra for yawing and waves (less with a snubber)."),
        Item(title: "Chain and holding", text: "Chain lying on the bottom, the pull angle at the anchor, when it lifts off, and the anchor's rough holding for its type and the bottom."),
        Item(title: "Safe gust limit", text: "The lower of complete chain lift-off and estimated holding with a safety allowance, recalculated for each forecast hour. It is a planning threshold, not a measured failure speed."),
        Item(title: "Tide and current", text: "Depth through the day from the nearest tide station; current from the nearest current station; depth at the next high."),
        Item(title: "Looking ahead", text: "Thin water under the keel, short scope at high water, gusts beyond your limit, swings of 90° or more that may require the anchor to reset, and forecast hull/swing clearance near a marked hazard."),
        Item(title: "Clearance", text: "Distance from anchor to hazard, less its keep-off distance, less the stern's reach: the rode taut at low water plus the boat's length."),
    ]

    var body: some View {
        List {
            section("Watch screen", watch)
            section("Tabs", tabs)
            section("Dropping and watching", dropping)
            section("What it works out", maths)
            Section {
                NavigationLink("Full User Guide") { UserGuideView() }
            } footer: {
                Text("These are estimates to help your judgement, not guarantees. Keep a lookout.")
            }
        }
        .navigationTitle("Quick Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ items: [Item]) -> some View {
        Section(title) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.bold())
                    Text(item.text).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
