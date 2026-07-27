# voxai-mcp

Companion MCP server for [VoxAI](https://apps.apple.com/app/id6766570591) — it gives your AI **ears** (live, speaker-labeled meeting transcripts) and a **voice** (speech on your Mac).

Everything stays on your machine. The server talks to the VoxAI app through its local container; no audio and no transcript ever leaves your Mac through this server.

## Install

One command, no sudo — it's a notarized universal binary:

```bash
mkdir -p ~/.local/bin && \
  curl -fsSL https://github.com/Ethan-YS/voxai-mcp/releases/latest/download/voxai-mcp-macos-universal.zip \
  -o /tmp/voxai-mcp.zip && unzip -o /tmp/voxai-mcp.zip -d ~/.local/bin && \
  chmod +x ~/.local/bin/voxai-mcp
```

Then register it with your AI client as a stdio MCP server pointing at `~/.local/bin/voxai-mcp`.

**You normally don't need to do any of this by hand.** Open VoxAI → Settings → *Connect Your AI* → **Copy Prompt**, paste it to your AI, and it will install and connect itself.

## Why the server ships separately

The VoxAI app is distributed through the Mac App Store, and sandboxed App Store apps can't ship a helper that an external process (your AI client) is allowed to launch — a bundled executable must carry a sandbox entitlement, and one that inherits it can only be sub-launched by its parent app. Compliant means unlaunchable; launchable means non-compliant. So the server lives here instead, outside the store, signed and notarized under the same Developer ID.

## Tools (14)

**Listening**
| | |
|---|---|
| `start_listening` / `stop_listening` | check in / out as the user's copilot — the app shows your name |
| `get_live_transcript` | poll new segments with a cursor |
| `list_meetings` / `get_meeting` | browse and read past sessions |
| `rename_meeting` | give a session a real title |
| `push_advice` | surface a note to the user, live, during the session |

**Speaking**
| | |
|---|---|
| `speak` / `stop_speaking` | talk through the user's Mac |
| `list_voices` | what's available (system voices, or Qwen if installed) |
| `install_voice_component` | install the higher-quality voice component on request |
| `update_voice_config` | engine / voice / rate |

**Voice chat**
| | |
|---|---|
| `get_dialog_input` / `post_dialog_reply` | the floating dialog panel: hear the user, reply in a bubble |

## Requirements

- macOS 14+
- The [VoxAI](https://apps.apple.com/app/id6766570591) app — this server is useless without it; it reads the app's data and drives its UI

## Build from source

```bash
swift build -c release
```

`release.sh <version>` does the full distribution build: universal binary → Developer ID signing → zip → notarization → Gatekeeper verification.

## Running it on Linux (and why you probably shouldn't)

The server builds and runs on Linux, and it will complete the MCP handshake and
report all 14 tools. It cannot do anything useful there: every tool reads or
writes IPC files inside the VoxAI macOS app's sandbox container, and that app
only exists on macOS. On a non-macOS host each tool call answers with a plain
message saying exactly that, rather than silently returning empty data.

```bash
docker build -t voxai-mcp .
docker run --rm -i voxai-mcp     # speaks MCP over stdio; tools report "needs the macOS app"
```

This exists so that directory sites which verify servers by starting them in a
container are checking *this* server, not a stand-in written to pass the check.
If you want the tools to actually work, install VoxAI on macOS 14+ and run the
server there.

## License

Proprietary — see [LICENSE](LICENSE).

You may download, install, and run this connector on machines you own or
control, including at work, when using it together with VoxAI. You may not
modify it, redistribute it, or use it to build a competing product.

The source is published here so that anyone can read what a program they run on
their own machine actually does. That transparency is the point; it is not an
open-source grant.
