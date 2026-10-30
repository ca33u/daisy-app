//
//  main.swift
//  DaisyLLM (XPC service inside Daisy.app)
//
//  «Локальная модель Daisy»: the summary model runs here, not in Daisy, so
//  its 4–7 GB never sit next to Whisper — under memory pressure macOS kills
//  this process and the summary is retried, the recording is untouched —
//  and an MLX crash takes only the helper. launchd starts it on Daisy's
//  first message; it exits a minute after its last request, and with it
//  the model's memory. See Packages/DaisyLLM.
//

import Foundation
import DaisyLLMEngine
import DaisyLLMKit

let service = DaisyLLMService(backend: DaisyMLXBackend(), idleTimeout: .seconds(60)) {
    exit(0)
}
let listener = NSXPCListener.service()
listener.delegate = service
service.start()
listener.resume()
