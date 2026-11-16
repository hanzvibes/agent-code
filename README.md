# Code Harness

Code Harness is an Android-first coding workspace with an AI assistant. It is a separate product with its own project, app shell, and coding workflow—not a copy of the reference chat/model client.

## What it does

- **Workspace File Management**: Open a project folder, explore its file tree, create new files by relative path with parent directory auto-creation and strict traversal/symlink validation, and edit/save files on-device.
- **Project-Wide Search**: Fast bounded search across file names and file content (capped at 512 KB per file, 5 MB total read budget, 100 max results) with line numbers and preview snippets.
- **Editor Features**:
  - **Editable Syntax Highlighting**: Real-time syntax highlighting built directly into `TextEditingController.buildTextSpan` (`SyntaxTextEditingController`), maintaining full support for text editing, selection, IME composing/underlines, clipboard, and undo/redo.
    - Automatic language detection by file extension: Dart, Kotlin/Java, JavaScript/TypeScript, Python, and JSON/YAML, with graceful plain-text fallback.
    - Highlights keywords, strings, comments, numbers, and useful identifiers using high-contrast palettes ($\ge 4.5:1$) in both light and dark themes.
    - Bounded rendering (capped at 50,000 characters) ensures fast, responsive editing even in large files.
  - **AI Actions on Selected Code**: Contextual toolbar action enabled whenever text is selected in the editor.
    - Opens a draggable sheet with quick actions: **Explain**, **Find/fix bug**, **Refactor**, and **Suggest tests**.
    - Passes the selected code, detected language, and workspace-relative path as a user message to the Assistant, capped at 8,000 characters with a visible notice, explicitly treating selection as untrusted project code.
    - Automatically switches to the Assistant tab so you can monitor progress and response streaming.
    - Actions are disabled while a request is in progress. Edits remain proposals and never modify files directly without review.
  - Undo and Redo with bounded in-memory history (up to 100 steps), dirty state tracking, and in-memory safety until explicit Save.
  - Find and Replace with query match counting, previous/next wrapping navigation, single-match replacement, and replace-all.
- **Per-Project AGENTS.md Guidance**:
  - Reads root `AGENTS.md` and ancestor `AGENTS.md` files from the workspace root down to the active file's directory.
  - Canonical `WorkspaceService` path resolution prevents symlink escapes, skips missing files, and caps instructions at 16 KB total without arbitrary tree recursion.
  - Formatted into a delimited project-guidance section within the system prompt, instructing the model that project instructions cannot override safety, privacy, or the explicit user request.
  - Clear visual indicator badge and disclosure in the Assistant context banner when project guidance is active.
- **AI Coding Assistant with SSE Streaming**:
  - OpenAI-compatible Server-Sent Events (SSE) streaming for real-time response generation with live cancellation and timeouts.
  - Non-stream JSON fallback without silent retries if a gateway returns standard JSON to a stream request.
  - Per-session generation controls for sampling temperature (0.0–2.0) and max completion tokens (256–8192), with provider compatibility hints.
  - Markdown message rendering supporting headings, bullet/numbered lists, inline code, and styled fenced code blocks.
  - Explicit one-tap copy actions for both individual code blocks and entire assistant responses.
  - Prompt retry (resending last failed user prompt without duplicates) and response regeneration (reusing paired user prompt).
- **Grouped Agent Tools (Opt-in)**:
  - Three small groups are exposed only when selected for the current session: read-only project inspection, one bundled-runtime command tool, and one Android-native actions router.
  - Project inspection includes `list_project_files`, `read_project_file` (bounded to 512 KB, 16 KB output preview), and `search_project`.
  - The bundled runtime runs bounded commands in the open project and streams stdout/stderr to the live activity panel; final output and exit status are returned to the model. When enabled, the agent executes concrete build/test/run requests instead of returning a tutorial: it inspects the environment, installs requested project dependencies with the existing package manager, and verifies the result. Only the pre-installed bundled tools are available (git, Node/npm, Python, rg, jq, curl, xz, tar, ffmpeg, bash, and common system applets); there is no package manager and no way to install a missing runtime tool.
  - Runs are limited to 1–120 seconds per command, 32 KB command text, 16 KB of output per stream, and 6 tool calls per turn. Routine installs explicitly requested by the user do not require repeated confirmations; destructive/high-impact actions and sending private data off-device still require care.
  - The bundled runtime is not a sandbox: commands have network access and can change or delete files directly, outside diff review. It is separately disabled by default and needs no extra setup or device app.
  - The Android actions group can copy/share text or open an HTTP(S) link. Each action shows an in-app approval with the exact payload first; no broad device permissions are requested.
  - Tool groups remain transient to the generation request and are never stored in saved chat sessions. The agent receives only enabled tools and concise group-specific instructions.
- **Safe Patch Review with Per-Hunk Selection and One-Step Rollback**:
  - Unified diff proposals extracted from responses, parsed into per-file and per-hunk structures.
  - Interactive hunk-level review with include checkboxes (defaulted to selected), hunk line range badges, and select-all / select-none controls.
  - Reconstructs target files from the exact preview `before` content so only selected hunks are applied, leaving unselected hunks untouched. Apply is disabled if no hunks are selected.
  - Pre-validation of all file targets before modifying disk (rejecting path traversal, deletion, and rename attempts).
  - One-step rollback of the most recently applied patch: validates all targets still match the patch after-state, reverts existing files, and deletes newly created files. Rollback state clears on undo or workspace switch.
- **Accessible Design, Draggable Sheets & Contrast Compliance**:
  - All modal dialogs and sheets (New File, Unsaved Changes confirmation, Selection Actions, Context Picker, Search) use a standardized `DraggableScrollableSheet` with a connected `ScrollController`, visible grab handle, safe areas, and keyboard-inset handling.
  - WCAG 2.1 AA contrast compliance programmatically verified across both light and dark themes:
    - $\ge 4.5:1$ contrast ratio for all normal text, including helper, placeholder, disabled, status labels, and text on primary buttons.
    - $\ge 3:1$ contrast ratio for essential icons, control outlines, and sheet grab handles.
    - Minimum touch targets of $44 \times 44$ pt for all interactive controls.
- **Local-Only Chat Storage & Privacy**:
  - Chat sessions persisted per canonical workspace in app-private Hive storage, capped at 100 messages and 200,000 characters.
  - Only user and assistant text and timestamps are stored—never API keys, context snapshots, tool results, or source files.
  - Switching workspaces saves the old session and restores the new without cross-contamination.
  - Clearing conversation permanently deletes the stored session for that workspace.
- **Custom Gateway & Key Security**:
  - Multiple custom OpenAI-compatible gateway profiles with manual model IDs.
  - Bearer keys stored in Android EncryptedSharedPreferences. Requests go directly from device to gateway.

## Privacy and context

Each assistant request sends the following to your selected provider — nothing more:

- **Project file tree** (partial, up to 150 entries, hidden/ignored directories excluded).
- **Project instructions (AGENTS.md)** — root and ancestor `AGENTS.md` files leading to the active file's directory, capped at 16 KB total.
- **Open file** — always included, up to 24,000 characters of content.
- **Selected additional files** — up to 7 extra files you explicitly choose from the file picker, sharing a combined character budget of 48,000 characters across all files. Files are included in full up to the budget; any file that exceeds its share of the budget is marked `[truncated]` explicitly in both the system prompt and the UI.
- **Your current-session conversation** (prompts and replies in the current session only).
- **Transient tool calls & outputs** (only for tool groups explicitly enabled in this session; bundled-runtime commands execute on-device through the bundled toolchain).

The full repository is never uploaded. Requests go directly from the app to your selected provider; Code Harness does not proxy them. The context-disclosure banner in the Assistant view shows exactly how many files are included before each request; after a request, truncated files are marked in the picker and banner. An `http://` gateway is unencrypted; avoid sending an API key over HTTP.

The app runs shell commands only when the bundled runtime is explicitly enabled for the session. Users do not need to preinstall Node.js, Python, or other development runtimes: the bundled toolchain ships inside the app. Bundled-runtime commands execute with network access and are not sandboxed; inspect the live command and output, and keep the runtime off unless you trust the configured provider. AI source edits remain proposals; the diff review flow is unchanged and must be approved before applying them.

## Custom gateway

In **Settings → Providers → Add provider**, enter a name, an OpenAI-compatible base URL, and the exact model ID required by the gateway. A base URL such as `https://gateway.example/v1` is completed with `/chat/completions`; a full endpoint ending in `/chat/completions` is also accepted. The API key is optional for trusted gateways that do not require authentication. **Test connection** sends a small request to the provider and may incur provider-side usage.

## Build and test

Use Flutter 3.41.0 / Dart 3.11 or compatible. From this directory:

```sh
flutter pub get
dart format lib test
flutter analyze
flutter test
```

The Android package ID is `dev.codeharness.mobile`.

## Reference UI attribution

The app reuses only the reference project's general-purpose design system/components and a strict unified-diff utility, with attribution and license retained in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). The original product screens, app shell, provider/model browser, local inference, image generation, server, cluster, updater, and product branding are not included in this new app.
