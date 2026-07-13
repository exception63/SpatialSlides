//
//  AppModel.swift
//  Spatial Slides
//
//  Created by zhouliying on 10/07/2026.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// When true the show plays inside a full immersive environment (a dark studio)
    /// instead of AR passthrough. Toggled from the remote; the Digital Crown can
    /// also dial immersion.
    var fullImmersion = false
}
