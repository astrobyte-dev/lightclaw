# lightclaw

> Control Adobe Lightroom Classic with AI through OpenClaw — adjust sliders, apply develop settings, manage masks, and edit metadata, all via natural language.

An MCP bridge that connects **OpenClaw** to **Adobe Lightroom Classic**, giving AI agents full control over develop settings, masks, collections, and metadata.

> **Windows support:** This fork adds full Windows compatibility. The original project targeted macOS only.

---

## What It Does

- Adjust any develop slider (Exposure, Contrast, Shadows, Highlights, HSL, etc.)
- Apply multiple settings at once
- Create and apply develop presets and snapshots
- AI masking (subject, sky, background, object, etc.)
- Manage collections, ratings, labels, pick flags
- Export photos as JPEG
- Undo/redo, auto tone, auto white balance
- 59 tools total — full Lightroom Classic control via natural language

---

## Requirements

- Adobe Lightroom Classic (Windows or macOS)
- Python 3.11+
- [OpenClaw](https://openclaw.ai) with mcporter

---

## Installation

### 1. Clone & set up Python environment

```powershell
git clone https://github.com/astrobyte-dev/lightclaw.git
cd lightclaw
python -m venv .venv
.venv\Scripts\activate
pip install -e .
```

### 2. Install the Lightroom plugin

Copy the plugin folder to Lightroom's auto-discovery directory:

**Windows:**
```powershell
Copy-Item -Recurse plugin\LightroomMCPCustom.lrplugin `
  "$env:APPDATA\Adobe\Lightroom\Modules\LightroomMCPCustom.lrplugin"
```

**macOS:**
```bash
cp -r plugin/LightroomMCPCustom.lrplugin \
  ~/Library/Application\ Support/Adobe/Lightroom/Modules/
```

Then restart Lightroom. The plugin appears in **File → Plug-in Manager** as **Lightroom MCP Custom** (green = enabled).

### 3. Register with OpenClaw via mcporter

**Windows:**
```powershell
mcporter add lightroom-classic `
  --stdio ".venv\Scripts\python.exe -m lightroom_mcp_custom.server"
```

**macOS:**
```bash
mcporter add lightroom-classic \
  --stdio ".venv/bin/python -m lightroom_mcp_custom.server"
```

### 4. Verify

```powershell
mcporter call lightroom-classic lightroom_ping
```

Expected: `{ "pong": true, "version": "0.4.0", "plugin": "Lightroom MCP Custom" }`

---

## Usage Examples

```powershell
# Single slider
mcporter call lightroom-classic set_develop_param parameter=Exposure value=0.5

# Multiple sliders at once
mcporter call lightroom-classic apply_develop_settings --args '{\"settings\":{\"Contrast\":45,\"Exposure\":0.5,\"Shadows\":-20}}'

# Read current settings
mcporter call lightroom-classic get_develop_settings

# Auto tone
mcporter call lightroom-classic auto_tone

# Create a named snapshot
mcporter call lightroom-classic create_snapshot name=BeforeEdit

# AI mask (subject, sky, background, person, object, depth, luminance, color)
mcporter call lightroom-classic create_ai_mask mask_type=subject

# Export selected photos as JPEG
mcporter call lightroom-classic export_photos destination=C:\exports quality=95
```

---

## How It Works

The Lightroom plugin (`LightroomMCPCustom.lrplugin`) opens two TCP sockets using Lightroom's `LrSocket` API:

| Socket | Mode | Role |
|---|---|---|
| `receive_port` | `"receive"` | Python writes JSON commands here; Lua's `onMessage` fires and dispatches them |
| `send_port` | `"send"` | Lua sends JSON responses back to Python here |

The Python MCP server maintains persistent connections to both ports. Commands are matched to responses via unique request IDs. Port numbers are written to `%TEMP%\lightroom_mcp_custom_ports.json` on startup.

---

## Windows Fixes (vs original)

| Problem | Fix |
|---|---|
| `/tmp/` path doesn't exist on Windows | Uses `LrPathUtils.getStandardFilePath("temp")` |
| PowerShell adds UTF-8 BOM to Lua files, breaking the parser | Deploy Lua files with `[System.IO.File]::WriteAllText` + `New-Object System.Text.UTF8Encoding $false` |
| Develop sliders didn't visually update after write | Added `LrDevelopController.setValue()` after `applyDevelopSettings()` |
| Wrong socket used for commands (receive-mode never fires `onMessage` for raw TCP) | Corrected two-socket architecture: write commands to `receive_port`, read responses from `send_port` |

---

## Credits

Based on [lightroom-classic-mcp](https://github.com/4xiomdev/lightroom-classic-mcp) by [4xiomdev](https://github.com/4xiomdev).
Windows fixes and OpenClaw integration by [astrobyte-dev](https://github.com/astrobyte-dev).

---

## License

MIT