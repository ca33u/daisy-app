//
//  MCPStdioBridge.swift
//  Daisy
//
//  The stdio entry for clients whose MCP config takes only a command:
//  Claude (chats, Cowork and the Code tab all read
//  `claude_desktop_config.json`, which has no `url` field), Codex when
//  the access token is on, and the snippet for other apps.
//
//  It used to be `npx -y mcp-remote@…`, which needed Node.js — the one
//  thing a non-developer most often doesn't have, and with nvm or Volta
//  a client started from the Dock didn't find it either, so Daisy just
//  never showed up. It also fetched a package from npm on every start.
//
//  Now it's `/bin/sh` driving `/usr/bin/curl`, both part of every macOS:
//  nothing to install, nothing downloaded, no binary of ours to sign.
//  That's enough because POST /mcp is one JSON-RPC message in, one plain
//  JSON body out (or 202 with no body for a notification), and Daisy
//  serves requests without a session id (see `MCPServer`
//  `handleStreamableRequest`). So each line from the client becomes one
//  POST, and each non-empty answer one line back.
//
//  Stateless on purpose: with no session id to lose, the bridge outlives
//  a restart of Daisy's server — a request that can't connect is retried
//  for ~10 s. Only "couldn't connect" (curl 7) is retried, never a
//  request that may have reached Daisy. The session Daisy mints on
//  `initialize` is never presented again; it idles out and is the first
//  one evicted at the client cap, so it costs nobody a slot.
//
//  The token rides as a trailing argument, as it did with mcp-remote's
//  `--header`; the client's config file holds it either way.
//

import Foundation

nonisolated enum MCPStdioBridge {
    static let command = "/bin/sh"

    /// The script's `$0`. Bump the number whenever `script` changes:
    /// entries carrying an older name then read as "needs an update".
    static let name = "daisy-mcp-bridge-1"

    static func url(port: Int) -> String {
        "http://127.0.0.1:\(port)/mcp"
    }

    /// `["-c", script, name, url]`, plus the token when one is required.
    static func arguments(port: Int, token: String?) -> [String] {
        var arguments = ["-c", script, name, url(port: port)]
        if let token { arguments.append(token) }
        return arguments
    }

    /// POSIX sh (macOS runs it as bash 3.2 in POSIX mode). `$1` is the
    /// URL, `$2` the optional token, turned into curl's header arguments
    /// with `set --` because sh has no arrays. `Expect:` stops curl
    /// sending `Expect: 100-continue` before bodies over 1 MB, which
    /// Daisy's listener doesn't answer. `-q` (must come first) skips the
    /// user's `~/.curlrc` and `--noproxy '*'` their `http_proxy`: either
    /// one could send 127.0.0.1 through a VPN proxy or put headers into
    /// the output. An HTTP error whose body is JSON (Daisy's JSON-RPC
    /// parse error) is passed on as the answer; any other failure ends
    /// the bridge, and the client reports the server as disconnected.
    ///
    /// No line may start with `[` at column 0: Codex stores the script
    /// as a multi-line TOML string, and `CodexMCPConfig.daisySection`
    /// ends Daisy's section at the first such line.
    static let script = """
    url=$1
    if [ -n "$2" ]; then set -- -H "Authorization: Bearer $2"; else set --; fi
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      tries=0
      until out=$(printf '%s' "$line" | /usr/bin/curl -q -s --noproxy '*' --fail-with-body -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'Expect:' "$@" --data-binary @- "$url"); do
        rc=$?
        if [ "$rc" -eq 22 ]; then case $out in '{'*) break ;; esac; fi
        if [ "$rc" -ne 7 ] || [ "$tries" -ge 20 ]; then
          printf 'Daisy MCP bridge: curl exit %s: %s\\n' "$rc" "$out" >&2
          exit 1
        fi
        tries=$((tries + 1))
        /bin/sleep 0.5
      done
      [ -z "$out" ] || printf '%s\\n' "$out"
    done
    """
}
