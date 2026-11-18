//
//  KeepAwakePolicyTests.swift
//
//  Whether a stream keeps the Mac awake: its default, how a
//  persisted value resolves, and which combinations of policy and window
//  state hold the sleep assertion. Pure - no session or ProcessInfo involved.
//

import Testing
@testable import Glimmer

struct KeepAwakePolicyTests {

    /// Off: the setting left Settings, and the Mac's own sleep rules apply.
    @Test func freshInstallLetsTheMacSleep() {
        #expect(KeepAwakePolicy.defaultPolicy == .never)
        #expect(KeepAwakePolicy.persisted(rawValue: nil) == .never)
    }

    @Test func rawValuesResolveAndUnknownLandsOnTheDefault() {
        #expect(KeepAwakePolicy.persisted(rawValue: "always") == .always)
        // The retired three-way middle value migrates to "on".
        #expect(KeepAwakePolicy.persisted(rawValue: "whileShowing") == .always)
        #expect(KeepAwakePolicy.persisted(rawValue: "sometimes") == .never)
    }

    @Test func alwaysHoldsRegardlessOfTheWindow() {
        #expect(KeepAwakePolicy.always.holdsSleepAssertion(windowShowing: true))
        #expect(KeepAwakePolicy.always.holdsSleepAssertion(windowShowing: false))
    }

    @Test func neverHoldsNothing() {
        #expect(!KeepAwakePolicy.never.holdsSleepAssertion(windowShowing: true))
        #expect(!KeepAwakePolicy.never.holdsSleepAssertion(windowShowing: false))
    }

    @Test func everyPolicyHasAName() {
        for policy in KeepAwakePolicy.allCases {
            #expect(!policy.displayName.isEmpty)
        }
    }
}
