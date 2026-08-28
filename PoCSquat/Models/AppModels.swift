import SwiftUI
import SwiftData
import CoreLocation

// MARK: - WalkSessionRecord
//
// Persisted walk history. Waypoints and petDistances are stored as JSON blobs
// since SwiftData doesn't natively support arrays of Codable structs or
// [UUID: Double] dictionaries. All properties have defaults — required for
// CloudKit sync (CloudKit must be able to construct partial objects).

@Model
final class WalkSessionRecord {
    var id: UUID = UUID()
    var routeName: String = ""
    var date: Date = Date()
    var elapsedTime: TimeInterval = 0
    var totalDistance: Double = 0
    var lapCount: Int = 0
    var isLoop: Bool = false
    var activityType: String = "walking"
    var notes: String = ""
    // JSON-encoded [String] (UUID strings) — avoids [String] Transformable edge cases
    var activePetIdsData: Data = Data()
    // JSON-encoded [WaypointCoord]
    @Attribute(.externalStorage) var waypointsData: Data = Data()
    // JSON-encoded [String: Double] (keys are UUID strings)
    @Attribute(.externalStorage) var petDistancesData: Data = Data()
    var steps: Int = 0
    var isCommunityRoute: Bool = false
    var customRouteIdString: String? = nil
    var countsTowardRouteStats: Bool = true
    var stopCount: Int = -1    // -1 encodes nil (no data); ≥0 is a real stop count
    var flaggedPossibleVehicle: Bool = false

    init(from session: WalkSession) {
        id               = session.id
        routeName        = session.routeName
        date             = session.date
        elapsedTime      = session.elapsedTime
        totalDistance    = session.totalDistance
        lapCount         = session.lapCount
        isLoop           = session.isLoop
        activityType     = session.activityType
        notes            = session.notes
        steps            = session.steps
        isCommunityRoute = session.isCommunityRoute
        customRouteIdString     = session.customRouteId?.uuidString
        countsTowardRouteStats  = session.countsTowardRouteStats
        stopCount               = session.stopCount ?? -1
        flaggedPossibleVehicle  = session.flaggedPossibleVehicle
        activePetIdsData  = (try? JSONEncoder().encode(session.activePetIds.map(\.uuidString))) ?? Data()
        waypointsData     = (try? JSONEncoder().encode(session.waypoints)) ?? Data()
        let distStrings   = Dictionary(uniqueKeysWithValues: session.petDistances.map { (k, v) in (k.uuidString, v) })
        petDistancesData  = (try? JSONEncoder().encode(distStrings)) ?? Data()
    }

    func toWalkSession() -> WalkSession {
        let petIdStrings = (try? JSONDecoder().decode([String].self, from: activePetIdsData)) ?? []
        let waypoints    = (try? JSONDecoder().decode([WaypointCoord].self, from: waypointsData)) ?? []
        let distStrings  = (try? JSONDecoder().decode([String: Double].self, from: petDistancesData)) ?? [:]
        let distances    = Dictionary(uniqueKeysWithValues: distStrings.compactMap { k, v -> (UUID, Double)? in
            guard let uuid = UUID(uuidString: k) else { return nil }
            return (uuid, v)
        })
        return WalkSession(
            id:                    id,
            routeName:             routeName,
            date:                  date,
            elapsedTime:           elapsedTime,
            totalDistance:         totalDistance,
            waypoints:             waypoints,
            lapCount:              lapCount,
            isLoop:                isLoop,
            activePetIds:          petIdStrings.compactMap { UUID(uuidString: $0) },
            activityType:          activityType,
            notes:                 notes,
            petDistances:          distances,
            steps:                 steps,
            isCommunityRoute:      isCommunityRoute,
            customRouteId:          customRouteIdString.flatMap { UUID(uuidString: $0) },
            countsTowardRouteStats: countsTowardRouteStats,
            stopCount:              stopCount >= 0 ? stopCount : nil,
            flaggedPossibleVehicle: flaggedPossibleVehicle
        )
    }
}

// MARK: - PetProfileRecord

@Model
final class PetProfileRecord {
    var id: UUID = UUID()
    var name: String = ""
    var species: String = ""
    var breed: String? = nil
    var goalSteps: Int = 5000
    var accentColorIndex: Int = 0
    var isActiveOnWalk: Bool = false
    var customEmoji: String? = nil
    var ownerName: String? = nil
    var ownerPhone: String? = nil

    init(from pet: PetProfile) {
        id               = pet.id
        name             = pet.name
        species          = pet.species
        breed            = pet.breed
        goalSteps        = pet.goalSteps
        accentColorIndex = pet.accentColorIndex
        isActiveOnWalk   = pet.isActiveOnWalk
        customEmoji      = pet.customEmoji
        ownerName        = pet.ownerName
        ownerPhone       = pet.ownerPhone
    }

    func toPetProfile() -> PetProfile {
        PetProfile(
            id:               id,
            name:             name,
            species:          species,
            breed:            breed,
            goalSteps:        goalSteps,
            accentColorIndex: accentColorIndex,
            isActiveOnWalk:   isActiveOnWalk,
            customEmoji:      customEmoji,
            ownerName:        ownerName,
            ownerPhone:       ownerPhone
        )
    }
}

// MARK: - CustomRouteRecord

@Model
final class CustomRouteRecord {
    var id: UUID = UUID()
    var name: String = ""
    var totalDistance: Double = 0
    var isLoop: Bool = false
    var createdAt: Date = Date()
    @Attribute(.externalStorage) var waypointsData: Data = Data()

    init(from route: CustomRoute) {
        id            = route.id
        name          = route.name
        totalDistance = route.totalDistance
        isLoop        = route.isLoop
        createdAt     = route.createdAt
        waypointsData = (try? JSONEncoder().encode(route.waypoints)) ?? Data()
    }

    func toCustomRoute() -> CustomRoute {
        let waypoints = (try? JSONDecoder().decode([WaypointCoord].self, from: waypointsData)) ?? []
        return CustomRoute(id: id, name: name, waypoints: waypoints,
                           totalDistance: totalDistance, isLoop: isLoop, createdAt: createdAt)
    }
}

// MARK: - BookmarkedLocationRecord

@Model
final class BookmarkedLocationRecord {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var createdAt: Date = Date()

    init(from location: BookmarkedLocation) {
        id        = location.id
        name      = location.name
        address   = location.address
        latitude  = location.latitude
        longitude = location.longitude
        createdAt = location.createdAt
    }

    func toBookmarkedLocation() -> BookmarkedLocation {
        BookmarkedLocation(id: id, name: name, address: address,
                           latitude: latitude, longitude: longitude, createdAt: createdAt)
    }
}
