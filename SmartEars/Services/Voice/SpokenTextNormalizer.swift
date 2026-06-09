//
//  SpokenTextNormalizer.swift
//  SmartEars — Voice layer
//
//  Assistant text is authored for the EYE (markdown, links, emoji). Fed verbatim
//  to AVSpeechSynthesizer it reads "asterisk", "h t t p colon slash slash", and
//  emoji names. This is the ONE place that converts display text to spoken text.
//  It is pure + Sendable and applied at the TTS boundary so it covers EVERY
//  backend uniformly (weather/stock/news/email/alert handlers + LLM replies +
//  RootView fallbacks) without any caller opting in.
//

import Foundation

public enum SpokenTextNormalizer {

    /// Convert display text into clean spoken text.
    public static func normalize(_ input: String) -> String {
        var s = input
        s = replaceURLs(in: s)
        s = stripMarkdown(in: s)
        s = stripEmoji(in: s)
        s = collapseWhitespace(in: s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: URLs (do this BEFORE markdown so we keep [label](url) labels)

    private static func replaceURLs(in text: String) -> String {
        var out = text
        // Markdown links [label](url) -> spoken as just the label.
        out = regexReplace(out, pattern: #"\[([^\]]+)\]\((?:[^)]+)\)"#, template: "$1")
        // Bare URLs (http/https/www) -> drop entirely (replaced by a short word
        // so we don't leave a dangling preposition like "see at .").
        out = regexReplace(out, pattern: #"\b(?:https?://|www\.)\S+"#, template: "the link")
        return out
    }

    // MARK: Markdown

    private static func stripMarkdown(in text: String) -> String {
        var out = text
        // Fenced + inline code: drop the backticks, keep the inner text.
        out = out.replacingOccurrences(of: "```", with: " ")
        out = out.replacingOccurrences(of: "`", with: "")
        // Headers: leading #'s at line start.
        out = regexReplace(out, pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, template: "")
        // Bullets: leading "- ", "* ", "+ " at line start -> nothing.
        out = regexReplace(out, pattern: #"(?m)^\s{0,3}[-*+]\s+"#, template: "")
        // Bold/italic markers ** __ * _ around words -> remove the markers.
        out = regexReplace(out, pattern: #"(\*\*|__|\*|_)(.+?)\1"#, template: "$2")
        // Any stray remaining emphasis/markup chars.
        out = out.replacingOccurrences(of: "#", with: "")
        return out
    }

    // MARK: Emoji / symbols

    private static func stripEmoji(in text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C) {
                // Replace emoji with a space so neighboring words don't fuse.
                result.append(" ")
            } else if scalar.properties.isVariationSelector {
                continue
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: Whitespace

    private static func collapseWhitespace(in text: String) -> String {
        regexReplace(text, pattern: #"\s+"#, template: " ")
    }

    // MARK: Helper

    private static func regexReplace(_ text: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
