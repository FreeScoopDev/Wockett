import SwiftUI

// MARK: - Symbol Catalogue
//
// Single source of truth for every icon in the app.
// `isCustom` cases use Image(_:) (asset catalog); all others use Image(systemName:).
// Rule: fill = state (selected / active / running). Outline otherwise.

enum WktSymbol {
    // Navigation / Tab
    case home               // custom asset: wkt.home.pin
    case health             // heart
    case community          // pawprint
    case settings           // slider.horizontal.3
    case routes             // map

    // Activity modes
    case walk               // figure.walk
    case run                // figure.run
    case ride               // figure.outdoor.cycle
    case indoor             // figure.walk.treadmill
    case walkMotion         // figure.walk.motion (stationary/indoor walk HUD)
    case walkCircle         // figure.walk.circle (tip icon)

    // Route actions
    case routeTrail         // point.topleft.down.to.point.bottomright.curvepath
    case find               // magnifyingglass
    case place              // mappin.and.ellipse
    case buildRoute         // pencil
    case saved              // bookmark
    case share              // square.and.arrow.up
    case communityRoutes    // globe.americas

    // Session controls
    case play               // play.fill
    case pause              // pause.fill
    case stop               // stop.fill
    case finish             // flag (use filled: true for flag.fill)
    case discard            // trash
    case playCircle         // play.circle
    case pauseCircle        // pause.circle
    case stopCircle         // stop.circle
    case speakerOn          // speaker.wave.2
    case speakerOff         // speaker.slash

    // Metrics
    case steps              // figure.walk
    case distance           // ruler
    case time               // clock
    case pace               // speedometer
    case elevation          // chart.line.uptrend.xyaxis

    // Health
    case sleep              // bed.double
    case readiness          // waveform.path.ecg
    case calories           // flame

    // Community
    case records            // trophy
    case badges             // medal
    case calendar           // calendar
    case pets               // pawprint

    // UI chrome
    case success            // checkmark.circle
    case warning            // exclamationmark.triangle
    case info               // info.circle
    case close              // xmark.circle
    case refresh            // arrow.clockwise
    case notifications      // bell
    case notificationsOff   // bell.slash
    case chevronRight       // chevron.right
    case chevronLeft        // chevron.left
    case chevronDown        // chevron.down
    case chevronUp          // chevron.up

    // Actions
    case add                // plus
    case dismiss            // xmark (plain, no circle)
    case check              // checkmark (inline, no circle)
    case subtract           // minus
    case history            // clock.arrow.circlepath
    case upload             // arrow.up.circle
    case arrowRight         // arrow.right
    case loop               // arrow.triangle.2.circlepath
    case undo               // arrow.uturn.backward
    case openExternal       // arrow.up.right.square
    case link               // globe

    // Location
    case locationOn         // location.fill
    case locationOff        // location.slash.fill
    case mapPinFill         // mappin.circle (use filled: true for mappin.circle.fill)
    case person             // person (use filled: true for person.fill)
    case addCircle          // plus.circle (use filled: true for plus.circle.fill)

    // Walk/session specific
    case vehicle            // car.fill (driving-detection banner)
    case chat               // message.fill (session notes)
    case heat               // thermometer.high (heat advisory)
    case hydration          // drop (use filled: true for drop.fill)

    // Gait / health metrics
    case cadenceArrow       // arrow.forward
    case balanceFigure      // figure.stand
    case strideWidth        // arrow.left.arrow.right
    case openHealth         // heart.text.square

    // Community moderation
    case communityWave      // person.2.wave.2 (share badge to community)
    case communityFill      // person.2 (use filled: true for person.2.fill)
    case flagReport         // flag
    case blockUser          // nosign
    case cloudError         // exclamationmark.icloud
    case errorCircle        // exclamationmark.circle (use filled: true for .fill)

    // Scheduling / calendar
    case calendarClock      // calendar.badge.clock
    case calendarAdd        // calendar.badge.plus

    // Miscellaneous
    case pin                // pin.fill (pinned badge)
    case tap                // hand.tap (gesture hint)
    case envelope           // envelope (send feedback)
    case camera             // camera (debug screenshot)
    case appleLogo          // apple.logo (WeatherKit attribution)
    case cloudOff           // cloud.slash
    case lightning          // bolt.fill (PR / achievement flash)
    case tip                // lightbulb.fill (onboarding tips)
    case phone              // phone.fill
    case mapFill            // map.fill (primary CTA)
    case openInMaps         // map (external)
    case lock               // lock (use filled: true for lock.fill)
    case lockOpen           // lock.open
    case noteText           // note.text
    case notePlus           // note.text.badge.plus
    case timer              // timer
    case target             // target (goal)
    case percent            // percent (progress)

    var name: String {
        switch self {
        case .home:           return "wkt.home.pin"
        case .health:         return "heart"
        case .community:      return "pawprint"
        case .settings:       return "slider.horizontal.3"
        case .routes:         return "map"
        case .walk:           return "figure.walk"
        case .run:            return "figure.run"
        case .ride:           return "figure.outdoor.cycle"
        case .indoor:         return "figure.walk.treadmill"
        case .walkMotion:     return "figure.walk.motion"
        case .walkCircle:     return "figure.walk.circle"
        case .routeTrail:     return "point.topleft.down.to.point.bottomright.curvepath"
        case .find:           return "magnifyingglass"
        case .place:          return "mappin.and.ellipse"
        case .buildRoute:     return "pencil"
        case .saved:          return "bookmark"
        case .share:          return "square.and.arrow.up"
        case .communityRoutes: return "globe.americas"
        case .play:           return "play.fill"
        case .pause:          return "pause.fill"
        case .stop:           return "stop.fill"
        case .finish:         return "flag"
        case .discard:        return "trash"
        case .playCircle:     return "play.circle"
        case .pauseCircle:    return "pause.circle"
        case .stopCircle:     return "stop.circle"
        case .speakerOn:      return "speaker.wave.2"
        case .speakerOff:     return "speaker.slash"
        case .steps:          return "figure.walk"
        case .distance:       return "ruler"
        case .time:           return "clock"
        case .pace:           return "speedometer"
        case .elevation:      return "chart.line.uptrend.xyaxis"
        case .sleep:          return "bed.double"
        case .readiness:      return "waveform.path.ecg"
        case .calories:       return "flame"
        case .records:        return "trophy"
        case .badges:         return "medal"
        case .calendar:       return "calendar"
        case .pets:           return "pawprint"
        case .success:        return "checkmark.circle"
        case .warning:        return "exclamationmark.triangle"
        case .info:           return "info.circle"
        case .close:          return "xmark.circle"
        case .refresh:        return "arrow.clockwise"
        case .notifications:  return "bell"
        case .notificationsOff: return "bell.slash"
        case .chevronRight:   return "chevron.right"
        case .chevronLeft:    return "chevron.left"
        case .chevronDown:    return "chevron.down"
        case .chevronUp:      return "chevron.up"
        case .add:            return "plus"
        case .dismiss:        return "xmark"
        case .check:          return "checkmark"
        case .subtract:       return "minus"
        case .history:        return "clock.arrow.circlepath"
        case .upload:         return "arrow.up.circle"
        case .arrowRight:     return "arrow.right"
        case .loop:           return "arrow.triangle.2.circlepath"
        case .undo:           return "arrow.uturn.backward"
        case .openExternal:   return "arrow.up.right.square"
        case .link:           return "globe"
        case .locationOn:     return "location.fill"
        case .locationOff:    return "location.slash.fill"
        case .mapPinFill:     return "mappin.circle"
        case .person:         return "person"
        case .addCircle:      return "plus.circle"
        case .vehicle:        return "car.fill"
        case .chat:           return "message.fill"
        case .heat:           return "thermometer.high"
        case .hydration:      return "drop"
        case .cadenceArrow:   return "arrow.forward"
        case .balanceFigure:  return "figure.stand"
        case .strideWidth:    return "arrow.left.arrow.right"
        case .openHealth:     return "heart.text.square"
        case .communityWave:  return "person.2.wave.2"
        case .communityFill:  return "person.2"
        case .flagReport:     return "flag"
        case .blockUser:      return "nosign"
        case .cloudError:     return "exclamationmark.icloud"
        case .errorCircle:    return "exclamationmark.circle"
        case .calendarClock:  return "calendar.badge.clock"
        case .calendarAdd:    return "calendar.badge.plus"
        case .pin:            return "pin.fill"
        case .tap:            return "hand.tap"
        case .envelope:       return "envelope"
        case .camera:         return "camera"
        case .appleLogo:      return "apple.logo"
        case .cloudOff:       return "cloud.slash"
        case .lightning:      return "bolt.fill"
        case .tip:            return "lightbulb.fill"
        case .phone:          return "phone.fill"
        case .mapFill:        return "map.fill"
        case .openInMaps:     return "map"
        case .lock:           return "lock"
        case .lockOpen:       return "lock.open"
        case .noteText:       return "note.text"
        case .notePlus:       return "note.text.badge.plus"
        case .timer:          return "timer"
        case .target:         return "target"
        case .percent:        return "percent"
        }
    }

    var isCustom: Bool { self == .home }
}

// MARK: - Image Initializer

extension Image {
    init(wkt symbol: WktSymbol) {
        if symbol.isCustom {
            self.init(symbol.name)
        } else {
            self.init(systemName: symbol.name)
        }
    }
}

// MARK: - Icon Size

enum WktIconSize {
    case tab    // 26pt — tab bar glyphs
    case row    // 20pt — list rows, section headers, card icons
    case inline // 16pt — inline with body text, chevrons

    var points: CGFloat {
        switch self {
        case .tab:    return 26
        case .row:    return 20
        case .inline: return 16
        }
    }
}

// MARK: - Icon Modifier
//
// Use `filled: true` for state (selected, active, running, primary CTA).
// Use `onFill: true` for icons that sit on a solid colour fill — switches
// rendering from hierarchical to monochrome so layering doesn't darken.

struct WktIconModifier: ViewModifier {
    var size:   WktIconSize
    var tint:   Color
    var filled: Bool
    var onFill: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: size.points, weight: .semibold))
            .symbolRenderingMode(onFill ? .monochrome : .hierarchical)
            .foregroundStyle(tint)
            .symbolVariant(filled ? .fill : .none)
    }
}

extension View {
    func wktIcon(
        _ size: WktIconSize = .row,
        tint: Color = .earthCream,
        filled: Bool = false,
        onFill: Bool = false
    ) -> some View {
        modifier(WktIconModifier(size: size, tint: tint, filled: filled, onFill: onFill))
    }
}
