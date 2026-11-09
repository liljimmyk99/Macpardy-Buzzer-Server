//
//  ForwardedFor.swift
//  BuzzerHub
//
//  Which address a request came from, behind a reverse proxy (#103). Per-IP
//  rate limits key on this, so behind Caddy they see each phone, not Caddy.
//

import Foundation

public enum ForwardedFor {

    /// The client address to use for a request.
    ///
    /// When `trust` is off, or the header is missing or empty, it's the TCP
    /// peer. When on, it's the **last** entry of `X-Forwarded-For`: the one the
    /// trusted proxy in front of the server added. Earlier entries came from
    /// the client and could be made up to dodge a rate limit.
    ///
    /// Only turn `trust` on when the server is reachable through the proxy
    /// alone; otherwise anyone can pick their own address.
    public static func clientAddress(header: String?, peer: String, trust: Bool) -> String {
        guard trust, let header else { return peer }
        let last = header.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !last.isEmpty, last.count <= 64, last.allSatisfy(isAddressCharacter) else { return peer }
        return last
    }

    /// IPv4, IPv6 and bracketed forms only, so a header can't put arbitrary
    /// text into the log.
    private static func isAddressCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isHexDigit || ".:[]".contains(character))
    }
}
