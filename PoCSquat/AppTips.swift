import TipKit

// MARK: - App Tips
//
// Shown contextually — TipKit auto-throttles so users aren't bombarded.
// Each tip appears at most once unless reset.

// Shown on the home screen after the user's first walk, pointing out audio cues
struct AudioCueTip: Tip {
    static let firstWalkCompleted = Event(id: "first_walk_completed")

    var title: Text { Text("Audio Cues") }
    var message: Text? { Text("Tap the speaker icon during a walk to hear distance and pace updates — no need to look at your screen.") }
    var image: Image? { Image(systemName: "speaker.wave.2.fill") }

    var rules: [Rule] {
        #Rule(Self.firstWalkCompleted) { $0.donations.count >= 1 }
    }
}

// Shown when the user has added routes but never tried a free walk
struct FreeWalkTip: Tip {
    static let routeWalkStarted = Event(id: "route_walk_started")

    var title: Text { Text("Free Walk Mode") }
    var message: Text? { Text("No route planned? Tap the walk button on the home screen for an open-ended free walk that records your path as you go.") }
    var image: Image? { Image(systemName: "figure.walk.circle") }

    var rules: [Rule] {
        #Rule(Self.routeWalkStarted) { $0.donations.count >= 2 }
    }
}

// Shown on the route finder after the user has walked 3+ sessions
struct GaitHealthTip: Tip {
    static let sessionsLogged = Event(id: "sessions_logged")

    var title: Text { Text("Walking Health") }
    var message: Text? { Text("Scroll down on the home screen to see your gait metrics — speed, stride, and balance — tracked automatically by your iPhone.") }
    var image: Image? { Image(systemName: "waveform.path.ecg") }

    var rules: [Rule] {
        #Rule(Self.sessionsLogged) { $0.donations.count >= 3 }
    }
}

// Shown the first time a pet is added
struct PetWalkTip: Tip {
    var title: Text { Text("Walk With Pets") }
    var message: Text? { Text("Tap a pet emoji in the walk HUD to toggle them as active — Wockett tracks each pet's distance separately.") }
    var image: Image? { Image(systemName: "pawprint.fill") }
}

// Shown when the route list is non-empty and community tab hasn't been visited
struct CommunityRouteTip: Tip {
    static let communityTabVisited = Event(id: "community_tab_visited")

    var title: Text { Text("Community Routes") }
    var message: Text? { Text("Share your favourite routes and discover ones others have walked nearby.") }
    var image: Image? { Image(systemName: "globe.americas.fill") }

    var rules: [Rule] {
        #Rule(Self.communityTabVisited) { $0.donations.count == 0 }
    }
}
