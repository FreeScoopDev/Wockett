import SwiftUI
import Combine
import MapKit
import CoreLocation
import MessageUI
import UIKit

// MARK: - POI Support

enum WalkPOIFilter: String, CaseIterable {
    case cafe, park, food, restroom, pharmacy

    var emoji: String {
        switch self {
        case .cafe:     return "☕️"
        case .park:     return "🌳"
        case .food:     return "🍽️"
        case .restroom: return "🚻"
        case .pharmacy: return "💊"
        }
    }

    var label: String {
        switch self {
        case .cafe:     return "Café"
        case .park:     return "Park"
        case .food:     return "Food"
        case .restroom: return "Restroom"
        case .pharmacy: return "Pharmacy"
        }
    }

    var mkCategories: [MKPointOfInterestCategory] {
        switch self {
        case .cafe:     return [.cafe]
        case .park:     return [.park, .nationalPark]
        case .food:     return [.restaurant, .foodMarket, .bakery]
        case .restroom: return [.restroom]
        case .pharmacy: return [.pharmacy]
        }
    }

    // Light values are the original fixed palette; dark values are lifted so pins/chips
    // stay readable against earthBg instead of going muddy, matching the adaptive
    // treatment already used for pet accent colors and the activity tokens.
    var color: Color {
        switch self {
        case .cafe:
            return Color(UIColor { tc in tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.78, green: 0.58, blue: 0.38, alpha: 1)
                : UIColor(red: 0.52, green: 0.33, blue: 0.18, alpha: 1) })
        case .park:     return .earthGreen
        case .food:     return .earthOrange
        case .restroom: return .accentInfo
        case .pharmacy:
            return Color(UIColor { tc in tc.userInterfaceStyle == .dark
                ? UIColor(red: 0.90, green: 0.45, blue: 0.50, alpha: 1)
                : UIColor(red: 0.72, green: 0.22, blue: 0.28, alpha: 1) })
        }
    }
}

struct NearbyPOI: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let name: String
    let category: WalkPOIFilter
    let mapItem: MKMapItem
}

@MainActor
final class POIOverlayManager: ObservableObject {
    @Published var activeCategories: Set<WalkPOIFilter> = []
    @Published var pois: [NearbyPOI] = []
    @Published var selectedPOI: NearbyPOI? = nil

    private var lastFetchLocation: CLLocationCoordinate2D?

    func enable(_ category: WalkPOIFilter, near coordinate: CLLocationCoordinate2D?) {
        guard !activeCategories.contains(category) else { return }
        activeCategories.insert(category)
        guard let coord = coordinate else { return }
        if lastFetchLocation == nil { lastFetchLocation = coord }
        fetchCategory(category, near: coord)
    }

    func disable(_ category: WalkPOIFilter) {
        activeCategories.remove(category)
        pois.removeAll { $0.category == category }
        if selectedPOI?.category == category { selectedPOI = nil }
    }

    func refreshIfNeeded(near coordinate: CLLocationCoordinate2D) {
        guard !activeCategories.isEmpty else { return }
        if let last = lastFetchLocation {
            let dist = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard dist >= 300 else { return }
        }
        lastFetchLocation = coordinate
        for category in activeCategories { fetchCategory(category, near: coordinate) }
    }

    private func fetchCategory(_ category: WalkPOIFilter, near coordinate: CLLocationCoordinate2D) {
        Task {
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
            let request = MKLocalSearch.Request()
            request.region = region
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: category.mkCategories)
            request.resultTypes = .pointOfInterest
            let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
            let newPOIs = items.prefix(8).compactMap { item -> NearbyPOI? in
                guard let name = item.name else { return nil }
                return NearbyPOI(coordinate: item.location.coordinate, name: name,
                                 category: category, mapItem: item)
            }
            pois.removeAll { $0.category == category }
            pois.append(contentsOf: newPOIs)
        }
    }
}
