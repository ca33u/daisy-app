//
//  MeetingSummaryJSONSchema.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/MeetingSummaryJSONSchema.swift (macOS Daisy 1.0.7.72,
//  2026-09-19). Kept byte-for-byte where possible; changes are limited to
//  `public` access and the removal of Mac-only references, each marked
//  with `// DaisyLite:`. The Mac copy is the reference — fix there first.
//
//
//  One provider-neutral structured-output contract. Account clients pass
//  this schema to their local protocol; API clients continue using the same
//  `SummaryPrompt` + `CloudSummaryDTO` path without behavioural changes.
//

import Foundation

public nonisolated enum MeetingSummaryJSONSchema {
    public static let identifier = "daisy_meeting_summary"

    /// JSON Schema for the canonical `MeetingSummary` wire shape. Every
    /// provider must decode through `CloudSummaryDTO` and map into
    /// `MeetingSummary`; provider-specific response DTOs are not allowed.
    public static let json = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://mydaisy.io/schemas/meeting-summary.json",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "summary": { "type": "string" },
        "sections": {
          "type": "array",
          "items": { "$ref": "#/$defs/section" }
        },
        "actionItems": {
          "type": "array",
          "items": { "type": "string" }
        },
        "clientFollowUp": { "type": "string" }
      },
      "required": ["summary", "sections", "actionItems", "clientFollowUp"],
      "$defs": {
        "section": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "title": { "type": "string" },
            "bullets": {
              "type": "array",
              "items": { "$ref": "#/$defs/bullet" }
            }
          },
          "required": ["title", "bullets"]
        },
        "bullet": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "text": { "type": "string" },
            "children": {
              "type": "array",
              "items": { "$ref": "#/$defs/bullet" }
            }
          },
          "required": ["text", "children"]
        }
      }
    }
    """#

    public static var data: Data { Data(json.utf8) }
}
