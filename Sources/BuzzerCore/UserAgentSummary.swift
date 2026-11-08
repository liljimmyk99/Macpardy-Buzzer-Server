//
//  UserAgentSummary.swift
//  BuzzerCore
//
//  Shortens a phone browser's User-Agent header to "Safari 18 on iOS 18.1"
//  for buzzer log lines (#81).
//

import Foundation

public enum UserAgentSummary: Sendable {

    public static func shorten(_ userAgent: String?) -> String {
        guard let userAgent, !userAgent.isEmpty else { return "unknown browser" }
        let browser = browser(in: userAgent) ?? "Unknown browser"
        guard let os = operatingSystem(in: userAgent) else { return browser }
        return "\(browser) on \(os)"
    }

    // MARK: - Browser

    /// Checked in order: most browsers also claim to be Safari and Chrome.
    private static let browserTokens: [(token: String, name: String)] = [
        ("EdgiOS/", "Edge"),
        ("EdgA/", "Edge"),
        ("Edg/", "Edge"),
        ("OPR/", "Opera"),
        ("OPiOS/", "Opera"),
        ("SamsungBrowser/", "Samsung Internet"),
        ("CriOS/", "Chrome"),
        ("FxiOS/", "Firefox"),
        ("Firefox/", "Firefox"),
        ("Chrome/", "Chrome"),
    ]

    private static func browser(in ua: String) -> String? {
        for (token, name) in browserTokens {
            if let version = majorVersion(after: token, in: ua) {
                return "\(name) \(version)"
            }
        }
        if ua.contains("Safari/") {
            return majorVersion(after: "Version/", in: ua).map { "Safari \($0)" } ?? "Safari"
        }
        return nil
    }

    // MARK: - Operating system

    private static func operatingSystem(in ua: String) -> String? {
        if ua.contains("iPad"), let version = version(after: "CPU OS ", in: ua) {
            return "iPadOS \(version)"
        }
        if let version = version(after: "iPhone OS ", in: ua) {
            return "iOS \(version)"
        }
        if let version = version(after: "Android ", in: ua) {
            return "Android \(version)"
        }
        if ua.contains("Android") { return "Android" }
        if ua.contains("CrOS") { return "ChromeOS" }
        if ua.contains("Mac OS X") || ua.contains("Macintosh") { return "macOS" }
        if ua.contains("Windows") { return "Windows" }
        if ua.contains("Linux") { return "Linux" }
        return nil
    }

    // MARK: - Helpers

    /// "18" from "Version/18.1.1 …" when `token` is "Version/".
    private static func majorVersion(after token: String, in ua: String) -> String? {
        guard let range = ua.range(of: token) else { return nil }
        let digits = ua[range.upperBound...].prefix(while: \.isNumber)
        return digits.isEmpty ? nil : String(digits)
    }

    /// "18.1" from "iPhone OS 18_1_1 like …" (major.minor, underscores as dots).
    private static func version(after token: String, in ua: String) -> String? {
        guard let range = ua.range(of: token) else { return nil }
        let raw = ua[range.upperBound...].prefix { $0.isNumber || $0 == "_" || $0 == "." }
        let parts = raw.split(whereSeparator: { $0 == "_" || $0 == "." }).prefix(2)
        guard let first = parts.first, !first.isEmpty else { return nil }
        if parts.count == 2, parts.last != "0" {
            return "\(first).\(parts.last!)"
        }
        return String(first)
    }
}
