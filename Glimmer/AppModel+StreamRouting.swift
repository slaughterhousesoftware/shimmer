//
//  AppModel+StreamRouting.swift
//
//  Streams are told apart by token: AppModel's live state follows only
//  `currentStreamToken`. A stream that a Switch PC ended is still closing
//  while the next one connects; its late events and its end must not touch
//  the new stream's state.
//

import AppKit
import Foundation

extension AppModel {

    /// A stream's event: the live stream's go to `handleNativeEvent`; a
    /// retired one's are dropped.
    func route(_ event: StreamEvent, host: Host, token: UUID) {
        guard token == currentStreamToken else { return }
        handleNativeEvent(event, host: host)
    }

    /// A stream ended: the live one cleans up as always; a retired one leaves
    /// nothing behind but its activity record.
    func finishSession(host: Host, caughtError: Error?, token: UUID) {
        if token == currentStreamToken {
            cleanupAfterStream(host: host, caughtError: caughtError)
            return
        }
        recordStreamActivity(for: host.id)
        Diag.info("Switch: the previous stream (\(host.displayName, privacy: .private)) closed", "Stream")
    }
}
