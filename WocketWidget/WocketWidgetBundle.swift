import WidgetKit
import SwiftUI

@main
struct WocketWidgetBundle: WidgetBundle {
    var body: some Widget {
        WocketStepWidget()
        WocketStartWalkControl()
        WocketWalkLiveActivity()
    }
}
