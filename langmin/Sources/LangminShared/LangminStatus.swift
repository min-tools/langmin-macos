// LangminStatus.swift
// Shared progress wording for Langmin app workflows.
// Copyright 2026 Ilia Ross
// Licensed under PolyForm Strict 1.0.0 with additional permissions; see LICENSE.

import Foundation

// Shared progress stages for app workflows.
enum LangminProgressStage {
    // Generating an explanation of the supplied text.
    case explanation
    // Preparing audio for a result.
    case narration
    // Opening an already prepared result.
    case opening
    // Correcting spelling, grammar, and punctuation.
    case proofread
    // Rephrasing the source text.
    case rewrite
    // Shortening the source text.
    case rewriteConcise
    // Expanding the source text.
    case rewriteElaborate
    // Condensing the source into a summary.
    case summarize
    // Translating into the selected target languages.
    case translate
    // Looking up a word or expression.
    case dictionary
}

// progressStatusText(stage): Use the same progress text in the launcher and
// result windows.
func progressStatusText(for stage: LangminProgressStage) -> String {
    // Choose a localized progress verb that matches the actual request stage.
    switch stage {
    // Show explanation progress while the text response is being generated.
    case .explanation:
        return localized("explaining", "Explaining…")
    // Describe audio preparation separately from text generation.
    case .narration:
        return localized("preparing_narration", "Preparing narration…")
    // Indicate that the prepared result is opening.
    case .opening:
        return localized("opening_progress", "Opening…")
    // Use the proofreading verb for correction requests.
    case .proofread:
        return localized("proofreading", "Proofreading…")
    // Use the rephrasing verb for the default rewrite style.
    case .rewrite:
        return localized("rephrasing", "Rephrasing…")
    // Use the shortening verb for concise rewrites.
    case .rewriteConcise:
        return localized("tightening", "Tightening…")
    // Use the expansion verb for elaborate rewrites.
    case .rewriteElaborate:
        return localized("elaborating", "Elaborating…")
    // Use the summarizing verb for summaries.
    case .summarize:
        return localized("summarizing", "Summarizing…")
    // Use the translating verb for translation requests.
    case .translate:
        return localized("translating", "Translating…")
    // Use the lookup verb for dictionary requests.
    case .dictionary:
        return localized("looking_up", "Looking up…")
    }
}
