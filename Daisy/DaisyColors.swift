//
//  DaisyColors.swift
//  Daisy
//
//  The palette moved to the shared `DaisyDesign` package (backlog 5
//  E-1, 2026-09-19): `DaisyPalette` holds the light/dark hex pairs as
//  data, `DaisyDesign` turns them into `Color.daisy…` per platform
//  (NSColor(name:) here, a dynamic UIColor on the iPhone). Same names,
//  same values — this file only re-exports the module so the forty-odd
//  views that say `Color.daisyRecording` keep compiling untouched.
//
//  Daisy's warm amber signal echoes the familiar macOS recording cue and
//  the flower's yellow-orange centre. It is reserved for live capture.
//
//  Package: Packages/DaisyCore in this repository (shared with DaisyLite)
//  (product DaisyDesign). Change a colour THERE, never here.
//

@_exported import DaisyDesign
