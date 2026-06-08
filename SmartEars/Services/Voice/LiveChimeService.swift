//
//  LiveChimeService.swift
//  SmartEars — Voice layer
//
//  Real chime playback backed by AudioToolbox system sounds. SmartEars uses two
//  audible cues:
//    * A short "wake" chime when the assistant starts listening.
//    * An importance-scaled "alert" chime when a new alert is surfaced.
//
//  We use `AudioServicesPlaySystemSound` with built-in iOS system sound IDs so
//  there are no bundled audio assets to ship and no secrets involved. The IDs
//  below map to short, distinct UISounds that work over the AirPods route.
//

import Foundation
import AudioToolbox

/// Live chime service using AudioToolbox system sounds.
///
/// Conforms to `ChimeService` (Models.swift). Both methods are `async` to match
/// the protocol; system-sound playback itself is fire-and-forget (iOS plays it
/// asynchronously), so we simply trigger it and return.
public struct LiveChimeService: ChimeService {

    public init() {}

    /// Plays the short "I'm listening" wake chime.
    public func playWakeChime() async {
        AudioServicesPlaySystemSound(1113) // "Begin Recording"-style cue
    }

    /// Plays an alert chime whose tone scales with the alert's importance.
    public func playAlertChime(importance: Importance) async {
        let soundID: SystemSoundID
        switch importance {
        case .urgent:
            soundID = 1304 // more insistent alert tone
        case .high:
            soundID = 1007 // standard SMS-received tone
        default:
            soundID = 1003 // gentle "received" tone
        }
        AudioServicesPlaySystemSound(soundID)
    }
}
