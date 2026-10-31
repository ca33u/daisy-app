//
//  DaisyLLMCodeSigning.swift
//  DaisyLLMKit
//
//  Who may talk to whom: Daisy only to its own helper, the helper only to
//  Daisy — both signed by the same team as the running process. The team
//  is read from this process's own signature rather than written in, so a
//  build from a clone signed with another team still pairs with itself;
//  an unsigned or ad-hoc build has no team and checks nothing.
//

import Foundation
import Security

public enum DaisyLLMCodeSigning {
    public static let appIdentifier = "app.essazanov.Daisy"
    public static let helperIdentifier = DaisyLLMWire.serviceName

    /// The team identifier of this process's signature, if it has one.
    public static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// A requirement for a peer with `identifier` from this process's team,
    /// or nil when this process has no team to compare with.
    public static func requirement(forIdentifier identifier: String) -> String? {
        guard let team = ownTeam else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
