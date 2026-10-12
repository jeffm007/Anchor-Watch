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
        ("Keeping watch", [settingAnchor, alarmCircle, alarms, watchCheck, lockScreen]),
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
            "Open **Settings** (the gear) and check **Position source** is **iPhone GPS**.",
            "Open **Settings → Testing → Watch check and test siren** and tap **Test siren now** to hear how loud the alarm is.",
        ]),
        .heading("Each time you anchor"),
        .bullets([
            "Let the boat settle and the anchor bite, then wait for a good GPS reading (the green dot and ± under the boat's name, ideally under 26 ft).",
            "Tap **Drop Anchor Here**. The anchor symbol marks the spot and a green circle appears around it.",
            "Set the circle with **Alarm radius** on the **Anchor** tab. The **Water** tab works out how much rode to pay out and a suggested radius.",
            "Plug the phone in, turn the volume up, and glance at the **Watch check** if an orange or red bar shows.",
            "Sleep. If the boat leaves the circle, the siren sounds and the screen turns red.",
        ]),
        .heading("When you leave"),
        .bullets(["Tap **Raise** on the Anchor tab to stop watching. The circle, track and lock-screen card all go away."]),
        .tip("Try the whole thing at the dock first, using **Test siren in 15 seconds** and locking the phone, so you know the alarm works before you rely on it."),
    ])

    static let mainScreen = GuideTopic(id: "mainscreen", title: "The main screen", icon: "iphone", blocks: [
        .heading("Top"),
        .text("The boat's name, the GPS in use with its accuracy (green good, orange poor, red too poor to use), and a status on the right: **Holding**, **Check** (a forecast or watch problem to look at), **Moving away**, **Dragging**, **Outside circle** or **Alarm**. It stays at Outside circle after you silence the alarm, until the boat is back inside."),
        .text("**Tap the status** to drop the anchor when you're not anchored, or to raise it (or silence the alarm) when you are. It always asks first, since raising ends the watch."),
        .heading("The six tiles"),
        .bullets([
            "**Wind**: forecast speed with an arrow showing which way it blows, where it comes from and the gusts. Tap for the Weather tab.",
            "**Depth**: the depth you entered, moved up or down as the tide has changed since, and whether it's rising or falling. Tap for the Water tab.",
            "**Scope**: rode out against today's depth plus bow height. It drops as the tide rises. Tap for Anchoring.",
            "**Anchor**: Secure and which way the anchor lies, or a warning: Moving away (the boat steadily getting further off, past its earlier swing), Dragging (the swing itself has moved), Outside or ALARM. Tap for Anchoring.",
            "**Tide**: how much it will rise or fall to the next high or low, and when. Tap for the Water tab.",
            "**Distance**: from the anchor now, the furthest so far (Max), and the alarm radius. Orange near the circle, red outside it.",
        ]),
        .heading("Next 24 hours"),
        .text("Under the tiles, the app looks ahead through the tide predictions and the wind forecast and shows the **first thing that will go wrong**, with a countdown: thin water under the keel at low tide, short scope at high water, forecast gusts beyond what your setup holds (worked out again for each hour, since high water's shorter scope holds less), or a **swing**. Green means nothing in the next 24 hours. **Tap it** for the full list in time order, including smaller wind shifts and slack water."),
        .heading("Swings and anchor resets"),
        .text("Each hour the app works out which way the boat lies from the wind's push on the windage and the current's push on the hull together. When that turns by 90° or more, the boat swings round and the anchor has to turn and reset, so it's flagged with the cause: the wind going round, or the flood or ebb taking over in light wind. Current comes from the nearest NOAA current station (see the Water tab). Without one, a high or low in light wind (under 6 knots) is flagged instead, since the boat will likely swing with the current."),
        .heading("Notices"),
        .text("Under the chart: anything to look at now that isn't an alarm: weather alerts, gusts measured nearby and watch problems. Forecast trouble is in Next 24 hours above. Tap a notice to hide it for an hour (sooner if it gets worse), or its **›** to open the screen it's about. **Show hidden** brings them all back."),
        .heading("Tabs along the bottom"),
        .bullets([
            "**Watch**: this screen: status, position and the chart.",
            "**Anchor**: the verdict first (holding well, marginal or at risk, the safe gust limit, and whether the next 12 hours of forecast stay under it), the rode drawn from the side at low, now or high tide, your setup, the alarm radius and anchor controls, then **Conditions**, **Load analysis** and **Your boat**, which open with a tap.",
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
            "The **anchor** symbol's red point is exactly where you dropped it.",
            "The dashed line runs from the anchor to the bow.",
            "The small **dotted orange circle** round the anchor shows how far off the drop point may be: the GPS accuracy (±) when you dropped, plus the uncertainty in which way the bow pointed. The true spot is inside it about two times in three. It disappears if you move the anchor by hand.",
            "The purple line is the **track** of where the boat has been. It starts when you drop the anchor, or as soon as you're moving if **Settings → Track** is on.",
            "The label under the circle shows the **Alarm Radius**, and turns red when the alarm sounds.",
            "The **dashed cyan circle** is how far the boat can swing: the rode stretched taut at the lowest water in the next 24 hours, plus the boat's length, since it's the stern that sweeps the edge. Keep it clear of rocks, shallows and other boats. The **thick cyan arc** on it is where the wind and current are forecast to put the boat over the next 24 hours.",
        ]),
        .heading("Before you anchor"),
        .text("A panel over the chart shows how much rode to pay out and the **Drop Anchor Here** button. It fades after \(GuideFacts.controlsFadeSeconds) seconds so you can see the chart; **tap the chart** to bring it back. Once you're anchored it goes away, and the radius and anchor controls are on the Anchor tab."),
    ])

    // MARK: Keeping watch

    static let settingAnchor = GuideTopic(id: "anchor", title: "Setting and moving the anchor", icon: "arrow.down.to.line", blocks: [
        .heading("Dropping it"),
        .text("Tap **Drop Anchor Here** once the boat has settled. The app uses the average of the last \(GuideFacts.averagingSeconds) seconds of GPS positions, so one stray reading can't put the anchor in the wrong place."),
        .text("The phone is taken to be amidships, but the anchor goes over the bow, half a boat length ahead. So the app moves the drop point forward by half your boat length (from the Boat Profile) toward where the bow pointed: the direction you came in on over the last minute, if you moved at least 15 m (about 50 ft); otherwise into the forecast wind, if there's 5 knots or more. If it can't tell, it leaves the anchor at the phone and widens the dotted circle instead. A note in the Alarm radius section of the Anchor tab says which it used."),
        .bullets([
            "If GPS accuracy is worse than about 26 ft, an orange warning appears and the button reads **Drop Anchor Anyway**. Waiting a minute usually helps.",
            "If accuracy is worse than about 165 ft, the button is disabled. Move the phone near a window, or outside.",
        ]),
        .heading("Correcting it later"),
        .bullets([
            "**Long-press the anchor symbol and drag** it to fine-tune the position.",
            "**Move Anchor** on the Anchor tab: the app switches to Watch, then tap the chart where the anchor should be (or **Cancel**).",
            "**Anchor → Boat** (also on the Anchor tab) moves the anchor to the boat's bow (averaged position, moved forward along the rode).",
        ]),
        .text("Moving the anchor resets the Max distance and gives the alarm a fresh start."),
        .heading("Finding the anchor from the swing"),
        .text("After about 20 minutes at anchor, the app fits a circle to the edge of your swing to work out where the anchor really is. It shows a purple ring on the chart and a line in the Alarm radius section of the Anchor tab: either the swing agrees with your mark, or it says how far off the mark is with **Move there** to correct it. You can also **long-press the purple ring** on the chart, or tap it and choose **Move anchor here**, to move the anchor there. See **How Anchoring works it out** for the details."),
        .heading("Raising it"),
        .text("**Raise**, on the Anchor tab, ends the watch: it clears the anchor, the track and any alarm, and switches the audio and lock-screen card off."),
        .tip("Your anchor and radius are saved, so closing the app or restarting the phone doesn't lose the watch. If you reopen the app while at a different place, tap Raise first."),
    ])

    static let alarmCircle = GuideTopic(id: "circle", title: "The alarm circle, rode and scope", icon: "circle.dashed", blocks: [
        .heading("Choosing the radius"),
        .text("Drag the **Alarm radius** slider on the **Anchor** tab. The circle should be big enough for the boat to swing freely on its rode, plus some room for GPS error."),
        .heading("The Water tab"),
        .bullets([
            "Enter the **water depth** at the anchorage with the − and + buttons, or type it.",
            "Add the **tide**: the extra depth you expect (see Tides). The rode has to cover high water.",
            "Pick a **scope ratio**: 3:1, 5:1, 7:1 or 10:1. Use more scope in wind or a poor bottom.",
            "**Rode to pay out** = ratio × (depth + tide + bow height).",
            "**Suggested alarm radius** = how far the taut rode reaches, plus half the boat's length (the phone is assumed amidships), plus a safety margin. **Use suggested radius** applies it.",
        ]),
        .text("Bow height and boat length live in **Settings → Boat Profile**, and also in the **Scope calculator** (the link in the Alarm radius section of the Anchor tab) along with the safety margin. Nereus is set to 47 ft, or 50 ft with the swim deck lowered."),
        .text("If you enter the rode you carry in the Boat Profile, the scope screens warn when the scope calls for more than you have."),
        .tip("If the circle is too small for your GPS accuracy, the Watch check says so. A circle less than about 2½ times the GPS error invites false alarms."),
    ])

    static let alarms = GuideTopic(id: "alarms", title: "Alarms and Silence", icon: "bell.badge", blocks: [
        .heading("When the alarm sounds"),
        .text("A loud two-tone siren plays through the phone's speaker (even with the silent switch on), the phone vibrates, a notification appears, the circle and label turn red, and a red banner with a **Silence** button appears at the top."),
        .heading("What triggers it"),
        .bullets([
            "**Boat left the circle**: \(GuideFacts.confirmFixes) GPS readings in a row beyond the radius. To avoid false alarms, a reading must be outside by more than its own error (up to \(GuideFacts.discountCapPercent)% of the radius). Coming back inside restarts the count.",
            "**GPS signal lost**: no position for \(GuideFacts.gpsLostSeconds) seconds.",
            "**GPS too inaccurate**: positions keep arriving but none is usable for \(GuideFacts.gpsPoorSeconds) seconds.",
            "**Low battery**: \(GuideFacts.batteryAlarmPercent)% or less and not charging. You also get a quiet notice at \(GuideFacts.batteryNoticePercent)%, and another if the charger is unplugged.",
        ]),
        .heading("Anchor dragging warning"),
        .text("Separately from the siren, the app watches where the swing says the anchor is. If it moves steadily one way, a **red banner** says the anchor appears to be dragging, and a red arrow on the chart shows how far and which way. It can come well before the boat leaves the circle. It's a warning, not the siren: check your position and be ready to re-anchor. See **How Anchoring works it out** for how it decides."),
        .heading("Silence"),
        .text("**Silence** stops the siren. The same alarm can sound again after \(GuideFacts.snoozeSeconds) seconds if the problem is still there (\(GuideFacts.batterySnoozeMinutes) minutes for the battery alarm). Silencing one kind of alarm doesn't silence the others, and a drifting boat always takes over from a battery or GPS alarm."),
        .warning("Silence doesn't fix anything. If the boat really has dragged, deal with it, then check the circle and anchor position."),
    ])

    static let watchCheck = GuideTopic(id: "watchcheck", title: "Watch check and test siren", icon: "checklist", blocks: [
        .text("An orange or red bar on the main screen means the phone isn't ready to keep watch. Tap it, or open **Settings → Testing → Watch check and test siren**, for the full list."),
        .heading("What it checks"),
        .bullets([
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
            "**Test siren in 15 seconds** waits, so you can lock the phone or switch to another app first and prove it sounds from the background. The lock-screen card turns red and says it's a test.",
        ]),
        .tip("With an anchor set, the app keeps its audio quietly running so the siren can start instantly even when the phone is locked. It plays over music or a chart app without pausing it."),
    ])

    static let lockScreen = GuideTopic(id: "lockscreen", title: "Lock screen and Dynamic Island", icon: "lock.iphone", blocks: [
        .text("While an anchor is set, a card on the lock screen and a pill in the Dynamic Island show the distance from the anchor, the circle size and a progress bar."),
        .bullets([
            "**Green**: holding. **Orange**: something serious needs attention, such as very poor GPS. **Red**: an alarm is sounding.",
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

    static let charts = GuideTopic(id: "charts", title: "Charts and zooming", icon: "map", blocks: [
        .text("Tap the **map** button to choose a chart:"),
        .bullets([
            "**OpenSeaMap**: street map with buoys, lights and seamarks on top. Works worldwide and saves the areas you've viewed for use with a weak signal.",
            "**NOAA Charts (US)**: the official US electronic charts, with depth soundings and contours. Blank outside US waters.",
            "**Apple Maps**: the standard iPhone map.",
            "**Satellite + Seamarks**: satellite photos with the seamarks.",
        ]),
        .text("Zoom with **+** and **−**, or pinch. On the OpenSeaMap and NOAA charts, zooming in stops at the closest level that has map detail."),
        .warning("These charts are a backdrop for watching the anchor, not for navigation. Use your official charts, such as TZ iBoat or Navionics, for that."),
    ])

    static let wind = GuideTopic(id: "wind", title: "Wind overlay and conditions", icon: "wind", blocks: [
        .heading("The overlay"),
        .text("Tap the **wind** button (it glows orange when on)."),
        .bullets([
            "Each **arrow** points the way the wind is blowing, and the number below is the speed in knots.",
            "Colors: grey under 5, green 5–10, yellow 10–15, orange 15–20, red 20–25, purple over 25.",
            "Tap an arrow for the wind direction and gusts.",
            "**Blue numbered badges** are real measurements from nearby weather stations. Tap one for its name and latest reading.",
            "The **slider** at the bottom steps the forecast ahead, up to 48 hours.",
        ]),
        .heading("The wind card"),
        .text("With the overlay on, a card under the top bar compares the **forecast** at your position with the wind **measured now** at the nearest station. Forecasts are model estimates and can be wrong near land. Tap the card for the **Conditions** sheet: every nearby station's wind, waves, pressure (with a rising, steady or falling arrow), temperatures and visibility. **Show these stations on the chart** zooms out to find them."),
        .heading("Warnings (always on)"),
        .bullets([
            "**Gusts** at or above your limit (\(GuideFacts.gustDefaultKnots) knots unless you change it in Settings), forecast or actually measured nearby.",
            "A **wind shift** of \(GuideFacts.windShiftDegrees)° or more expected in the next 12 hours.",
        ]),
        .text("These appear as orange lines even when the overlay is off. They're heads-up notices only; they don't sound the siren."),
        .heading("Weather alerts"),
        .text("Official US National Weather Service watches and warnings, such as a Small Craft Advisory, appear as a banner. Tap it to read the full text. Serious and marine alerts also send a notification the first time they appear."),
    ])

    static let tides = GuideTopic(id: "tides", title: "Tides", icon: "water.waves", blocks: [
        .text("Open the **Water** tab. The Tide section finds the nearest tide station to you, in either the US or Canada, and lists the next highs and lows."),
        .bullets([
            "**Right now (estimated)** is the height above the chart's low-water level. It's an estimate drawn from the predicted highs and lows.",
            "Choose **Cover the next 6, 12 or 24 h**, then tap **Use tide data**. It fills in how far the water is expected to rise from now, so your rode covers high water.",
            "You can also set the tide by hand with the − and + buttons.",
        ]),
        .tip("Enter the depth you can see now, at the current tide, and let the tide field add the rise. If you enter the depth at high water, leave the tide at 0 so it isn't counted twice."),
        .warning("These are predictions. Wind and air pressure can raise or lower the water by a foot or more, especially on the Gulf coast. Leave a margin."),
    ])

    static let canada = GuideTopic(id: "canada", title: "Canadian waters", icon: "globe.americas", blocks: [
        .bullets([
            "**Works the same everywhere**: GPS, the alarm circle, scope, the wind overlay and forecast, battery and Watch check.",
            "**Tides**: the app picks the nearest station of either country, including Canadian Hydrographic Service stations.",
            "**Weather stations**: Environment Canada's stations join NOAA's, and the nearest ones are used.",
            "**Charts**: the NOAA layer is US only. OpenSeaMap works as a backdrop.",
            "**Weather alerts**: only US alerts are covered for now. For Canadian marine warnings, use VHF weather or Environment Canada.",
        ]),
        .tip("Cell data can be patchy in the islands and may cost roaming charges. Open the places you plan to visit while you have a signal; the chart tiles and tide data are kept on the phone."),
    ])

    // MARK: Reference

    static let settings = GuideTopic(id: "settings", title: "Settings", icon: "gearshape", blocks: [
        .bullets([
            "**User Guide**: this guide.",
            "**Boat Profile**: the boat's size, windage, anchor, rode and snubber. It feeds the scope, holding and wind-load maths. Leave anything you don't know blank.",
            "**Gust Warning**: the gust limit for the wind warnings.",
            "**Track**: draw the track under way, not only at anchor, and keep the way in after you drop the anchor. Raise clears it.",
            "**Fade Buttons**: fade the row of buttons under the chart when idle. Tap the chart to bring them back.",
            "**Units**: Metric or Feet.",
        ]),
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
            "Enlarge the circle. It should be well over twice the GPS error.",
            "Drop the anchor again once GPS is good, or use **Anchor → Boat**.",
        ]),
        .heading("The siren is quiet or silent"),
        .bullets([
            "Turn the volume up. The Watch check shows it.",
            "Disconnect Bluetooth speakers and AirPods.",
            "Use **Test siren** to confirm.",
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
        .text("The weather, tide and alert services receive your approximate position to find the nearest data. Your anchor position and track stay on the phone."),
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
