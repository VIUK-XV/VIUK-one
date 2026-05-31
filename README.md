# VIUK One

VIUK One は、Web、学習、AI、ストーリー体験をひとつのワークスペースから扱う SwiftUI アプリです。

旧プロジェクト名として `SafeKids Search3.1` がパスやスキーム名に残っていますが、アプリ上の表示名は `VIUK One` です。

## What This Project Is

VIUK One is a SwiftUI workspace hub for family-oriented browsing, learning, AI assistance, and interactive story experiences.

The project is not designed as one giant merged screen. It is a launcher and workspace shell where each internal app can keep its own data, settings, model/runtime state, and user experience. That separation is important because a learning tool, a safe browser, an AI assistant, and a character story engine have different safety needs and different UX expectations.

## Why It Matters

Modern AI apps often split into two extremes:

- Simple chat wrappers that are easy to start but weak at long-running user workflows.
- Complex AI workbenches that expose too much model/runtime detail to normal users.

VIUK One explores a middle path: a local-first, user-facing app where AI features are attached to concrete workflows such as learning, safe browsing, research, story generation, character sessions, and structured progress state.

The project is useful as an open SwiftUI reference for:

- AI-assisted app UX on macOS and iOS.
- Local/remote model fallback design.
- Safe handling of model installation state.
- Long-running story and chat sessions.
- Search-assisted AI workflows.
- Workspace-style app composition in SwiftUI.
- Avoiding hardcoded secrets in AI-enabled apps.
- Debugging real device issues around WebKit, local model runtimes, and responsive SwiftUI layouts.

## Project Goals

- Provide a single entry point for several VIUK workspaces without forcing them into one UI model.
- Keep AI usable for non-technical users by hiding raw model/runtime complexity where possible.
- Support both fast AI responses and slower reasoning-style workflows.
- Make story sessions feel persistent, stateful, and understandable instead of being plain chat logs.
- Keep local model experiments isolated enough that runtime failures do not break the whole app.
- Keep API keys, generated runtimes, caches, and large model files out of source control.

## Current Status

This repository is under active development.

- The UI and AI flows are changing quickly.
- Some runtime/model files may be local-only or excluded from the repository.
- Some folders and schemes still use the legacy `SafeKids Search3.1` name.
- The app should not be treated as production-ready security or safety software without additional review.
- API keys and private credentials must not be committed to source control.

## Main Workspaces

### Home

The home screen is the main launcher for VIUK workspaces. It should stay calm, direct, and useful: the user chooses the task first, then enters the appropriate workspace.

### Safe Browsing

SafeKids-origin web tools are still present as part of VIUK One. The current direction is to keep browser and safety controls scoped to the browsing workspace instead of leaking those controls into unrelated areas.

### AI Studio

AI Studio is a chat-first workspace for:

- Fast responses.
- Thinking-style responses.
- Deep research and search-assisted answers.
- Local AI runtime experiments.
- Model/runtime state display.
- Story and structured assistant workflows.

AI Studio should make the selected model and current state clear, while avoiding an experience where the user must understand every backend detail before asking a question.

### Story Workspace

The story workspace supports character-driven sessions with:

- Story definitions.
- Character profiles.
- Character images.
- Scene state.
- Conversation history.
- Speaker-aware generated messages.
- Progress state such as chapter, current objective, and latest story change.

The goal is to make story sessions feel like an interactive narrative workspace. The user should be able to understand what scene they are in, who is active, what changed in the last turn, and where the story is heading.

### Learning

The learning workspace is intended for study content, review flows, and AI-assisted learning experiences. It should remain separate from general AI chat so that learning data and learning UX can evolve independently.

### Map

The map workspace contains location/map-oriented tools. It is treated as its own workspace because map interactions have different layout, privacy, and permission needs from chat or story flows.

### Love / Relationship Experiments

The Love workspace contains relationship and story-adjacent interaction experiments. It should stay separate from the main AI Studio unless a feature clearly belongs in both places.

### Imported Apps

VIUK One also hosts imported app modules such as Science Club and other VIUK experiments. Imported modules should remain understandable as independent products even when launched from the shared home screen.

## AI Architecture Direction

The AI system is being designed around clear runtime boundaries:

- Local model state should be explicit: not installed, saved only, runnable, failed, or unavailable.
- Remote API-backed flows should not pretend to be local model execution.
- Local runtime failures should be contained and surfaced as recoverable app state.
- Search-assisted AI should keep search, synthesis, and UI state separate.
- Story generation should separate body generation from progress/state updates.

For story sessions, the target flow is:

1. Save the user message.
2. Generate the story response.
3. Split speaker/narration lines into story messages.
4. Generate a short progress update.
5. Save chapter/objective/last-turn progress.
6. Update the UI without losing the conversation.

This keeps the story readable even when a progress update fails.

## Maintenance Workflows

This project has several maintenance areas where code review and automation matter:

- SwiftUI layout regressions across macOS and iOS.
- Real-device crash investigation.
- WebKit behavior changes.
- Local model runtime integration.
- Story prompt and structured-output validation.
- Generated asset and large-file hygiene.
- Secret scanning and API key removal.
- Build validation after heavy UI iteration.

These are the kinds of workflows where Codex-style assistance is valuable: triaging issues, reviewing pull requests, finding unsafe commits, keeping README/spec docs current, and producing focused patches without resetting unrelated work.

## Potential Use of OpenAI API Credits

If API credits are available for OSS maintenance, the project can use them for:

- Regression tests for AI prompt behavior.
- Structured-output validation for story/session progress updates.
- Generating test fixtures for long-running chat and story sessions.
- Summarizing crash logs and issue reports.
- Assisting pull request review for SwiftUI and AI-flow changes.
- Creating small reproducible cases for runtime/model failures.
- Comparing prompt variants for safety, clarity, and consistency.

The goal would be maintenance support, not hiding application functionality behind private credentials.

## Tech Stack

- Swift
- SwiftUI
- SwiftData
- WebKit
- MapKit
- Local AI runtime experiments
- Vendored third-party runtime code under `ThirdParty/`

## Repository Layout

```text
SafeKids Search3.1/
  SafeKids Search3.1/
    App/              App entry point, brand constants, app-wide wiring
    Core/             Shared app infrastructure and reusable primitives
    Home/             VIUK One home workspace
    AI/               AI Studio, chat, search, story, and model/runtime logic
    Learning/         Learning workspace
    Map/              Map workspace
    Love/             Love/story-related workspace
    ImportedApps/     Imported VIUK app modules
    Legacy/           Legacy compatibility surfaces
  Scripts/            Build and maintenance scripts
  ThirdParty/         Vendored third-party code
```

## Build

Requirements:

- macOS
- Xcode

Open the project:

```text
SafeKids Search3.1/SafeKids Search3.1.xcodeproj
```

Build the `SafeKids Search3.1` scheme. The app product is branded as `VIUK One`.

For CLI builds, the repository includes an isolated build script:

```zsh
/Users/hikumasoutosabu/Documents/Playground/SafeKids\ Search3.1/Scripts/run-isolated-xcodebuild.sh CODE_SIGNING_ALLOWED=NO build
```

With a custom DerivedData directory:

```zsh
VIUK_DERIVED_DATA_DIR="/tmp/viuk-one-derived" \
  "/Users/hikumasoutosabu/Documents/Playground/SafeKids Search3.1/Scripts/run-isolated-xcodebuild.sh" \
  CODE_SIGNING_ALLOWED=NO build
```

## AI Models, Secrets, and Large Files

Do not commit:

- API keys.
- Private model credentials.
- `.xcode-home/`.
- `.xcode-cache/`.
- DerivedData.
- Local model caches.
- Generated `.xcframework` zip files.
- Large runtime artifacts over GitHub file size limits.

Local model availability may differ by machine. The app should handle missing models, failed runtime initialization, and unavailable accelerators as normal app states rather than fatal assumptions.

## GitHub Desktop Warning

If GitHub Desktop shows a "Files Too Large" warning, do not choose "Commit Anyway" for generated runtime files. Remove those generated paths from the commit selection and add ignore rules where appropriate.

Typical generated paths include:

```text
.xcode-home/
.xcode-cache/
DerivedData/
*.xcframework.zip
```

## Security and Privacy Notes

- This project should avoid committing real user data, API keys, private model tokens, or local cache contents.
- AI features should make runtime/source distinctions clear to the user.
- Browser and family-safety features need additional review before being described as production-grade safety tooling.
- Story and character features should preserve user agency and avoid unsafe dependency or coercive patterns.

## Open Source Readiness

The project is being prepared to be understandable from the repository alone:

- Root README explains the product direction.
- Generated files should be excluded from commits.
- Third-party code remains under `ThirdParty/` with its own licenses.
- Specs and implementation notes should be kept in sync with code as the AI and story systems evolve.

## Roadmap

- Improve iOS layout stability for story and AI chat screens.
- Strengthen AI runtime fallback behavior.
- Add clearer model state and model details UI.
- Expand story progress visualization.
- Improve character and image persistence.
- Add safer structured-output validation for story generation.
- Reduce accidental generated-file commits.
- Add focused test fixtures for AI prompt and session-state behavior.

## License

No root project license has been selected yet. Third-party code keeps its own license files under `ThirdParty/`.
