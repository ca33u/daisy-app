//
//  MeetingSummaryJSONSchema.swift
//  Daisy
//
//  One provider-neutral structured-output contract. Account clients pass
//  this schema to their local protocol; API clients continue using the same
//  `SummaryPrompt` + `CloudSummaryDTO` path without behavioural changes.
//

import Foundation

nonisolated enum MeetingSummaryJSONSchema {
    static let identifier = "daisy_meeting_summary"

    /// JSON Schema for the canonical `MeetingSummary` wire shape. Every
    /// provider must decode through `CloudSummaryDTO` and map into
    /// `MeetingSummary`; provider-specific response DTOs are not allowed.
    static let json = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://mydaisy.io/schemas/meeting-summary.json",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "title": { "type": "string" },
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
      "required": ["title", "summary", "sections", "actionItems", "clientFollowUp"],
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

    static var data: Data { Data(json.utf8) }

    /// The same shape two levels deep — a bullet's children are plain leaves
    /// — for «Локальная модель Daisy». Its grammar loop always takes the most
    /// likely token, and with `children` recursive a 67-minute meeting came
    /// out as one section nesting everything, a sub-block repeated three
    /// times; two levels gave four sections and twelve bullets (30.10, Л-1).
    /// Still a valid `CloudSummaryDTO`.
    static let localModelJSON = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://mydaisy.io/schemas/meeting-summary-local.json",
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "title": { "type": "string" },
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
      "required": ["title", "summary", "sections", "actionItems", "clientFollowUp"],
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
              "items": { "$ref": "#/$defs/leaf" }
            }
          },
          "required": ["text", "children"]
        },
        "leaf": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "text": { "type": "string" }
          },
          "required": ["text"]
        }
      }
    }
    """#

    /// `localModelJSON` for an API that holds its reply to a schema
    /// (Anthropic's `output_config.format`, 03.11.2026): two levels because
    /// such APIs refuse recursive schemas, nothing by `$ref`, no `$schema` /
    /// `$id`, and `title` only for the meeting summary — the one task whose
    /// prompt asks for it. Text, not a dictionary, because the model writes
    /// the fields in the schema's order: the envelope as the prompt lays it
    /// out, a bullet's `text` before its `children`. A dictionary through
    /// JSONSerialization came out in a different order each launch.
    static func constrainedReplyJSON(includesTitle: Bool) -> String {
        let leaf = #"{"type":"object","additionalProperties":false,"properties":{"text":{"type":"string"}},"required":["text"]}"#
        let bullet = #"{"type":"object","additionalProperties":false,"properties":{"text":{"type":"string"},"children":{"type":"array","items":"# + leaf + #"}},"required":["text","children"]}"#
        let section = #"{"type":"object","additionalProperties":false,"properties":{"title":{"type":"string"},"bullets":{"type":"array","items":"# + bullet + #"}},"required":["title","bullets"]}"#
        let title = includesTitle ? #""title":{"type":"string"},"# : ""
        let required = (includesTitle ? #""title","# : "") + #""summary","sections","actionItems","clientFollowUp""#
        return #"{"type":"object","additionalProperties":false,"properties":{"# + title
            + #""summary":{"type":"string"},"sections":{"type":"array","items":"# + section
            + #"},"actionItems":{"type":"array","items":{"type":"string"}},"clientFollowUp":{"type":"string"}},"required":["#
            + required + "]}"
    }
}
