//
//  SecureToken.swift
//  BuzzerHub
//
//  Random resume tokens and a constant-time comparison for the host token
//  (#103). Foundation-only: `SystemRandomNumberGenerator` reads the OS's
//  secure random source on macOS and Linux.
//

import Foundation

public enum SecureToken {

    /// `byteCount` random bytes as lowercase hex.
    public static func generate(byteCount: Int = 24) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Whether `a` and `b` are equal, taking the same time wherever they
    /// differ, so a wrong token's timing doesn't reveal how much of it was right.
    /// The length still shows; the token's length isn't the secret.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        var difference = UInt8(lhs.count == rhs.count ? 0 : 1)
        for index in 0..<max(lhs.count, rhs.count) {
            let x = index < lhs.count ? lhs[index] : 0
            let y = index < rhs.count ? rhs[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}
