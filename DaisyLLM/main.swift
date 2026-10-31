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

let service = DaisyLLMService(
    backend: DaisyMLXBackend(),
    idleTimeout: .seconds(60),
    // A generation that ignores its cancel this long is stuck in MLX or
    // Metal; leaving is the only way to give its memory back. `_exit`: a
    // thread is still inside MLX, so no atexit handlers or C++ static
    // destructors (Metal device, allocator) may run under it.
    cancelGrace: .seconds(30),
    onIdle: { exit(0) },
    onStuck: { _exit(1) })
let listener = NSXPCListener.service()
listener.delegate = service
service.start()
listener.resume()
