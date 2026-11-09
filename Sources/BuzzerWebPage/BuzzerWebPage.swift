//
//  BuzzerWebPage.swift
//  BuzzerWebPage
//
//  The phone buzzer page (buzzer.html), one self-contained file served at `/`
//  by both the app's built-in server and the self-hosted server (#103). It
//  lives in the package so both get the same page.
//

import Foundation

public enum BuzzerWebPage {

    /// The page's bytes, or nil if the resource is missing from the build.
    public static let html: Data? = {
        guard let url = Bundle.module.url(forResource: "buzzer", withExtension: "html") else { return nil }
        return try? Data(contentsOf: url)
    }()

    /// What to serve when `html` is missing, so phones see why.
    public static let missingPage = Data("<h1>Buzzer page not found</h1>".utf8)
}
