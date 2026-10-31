//
//  DaisyLLMInterfaces.swift
//  DaisyLLMKit
//
//  The two NSXPC interfaces: Daisy → helper (generate, cancel) and
//  helper → Daisy (progress). Payloads are `DaisyLLMWire` JSON.
//

import Foundation

@objc public protocol DaisyLLMServiceProtocol {
    /// `request` is a `DaisyLLMRequest`. The reply comes exactly once:
    /// a `DaisyLLMResponse`, or nil and a `DaisyLLMFailure`.
    func generate(_ request: Data, reply: @escaping @Sendable (Data?, Data?) -> Void)
    /// Cancels a queued or running request by its id (a UUID string). The
    /// request still replies, with `.cancelled`.
    func cancel(_ requestID: String)
    /// Memory is short: cancel everything and exit as soon as the running
    /// generation has stopped (at once if nothing runs).
    func shutdown()
}

@objc public protocol DaisyLLMProgressProtocol {
    /// `event` is a `DaisyLLMProgress`.
    func progress(_ event: Data)
}

public enum DaisyLLMInterfaces {
    public static func service() -> NSXPCInterface {
        NSXPCInterface(with: DaisyLLMServiceProtocol.self)
    }

    public static func progress() -> NSXPCInterface {
        NSXPCInterface(with: DaisyLLMProgressProtocol.self)
    }
}
