# iOS reference UI workflow

Use this runbook when changing the native `VocelloiOS` SwiftUI surface to match the interactive reference in `design_references/Vocello iOS/`.

The reference is a working React/CSS prototype, not a screenshot pack. Treat it as the visual source of truth for spacing, motion, sheets, dock behavior, and state transitions. Keep real native data flow and production defaults unless they create a visible mismatch; for visible iOS parity, the reference wins.

## Reference app

Primary files:

- `design_references/Vocello iOS/index.html` - browser entry point.
- `design_references/Vocello iOS/app.css` - layout, dimensions, shadows, glass, and state styling.
- `design_references/Vocello iOS/tokens.css` - mode colors and surface tokens.
- `design_references/Vocello iOS/studio.jsx` - Studio modes, lower controls, CTA, generating bar, inline player.
- `design_references/Vocello iOS/chrome.jsx` - status bar and tab dock.
- `design_references/Vocello iOS/sheets.jsx` - bottom sheets, pickers, install/delete panels.
- `design_references/Vocello iOS/player.jsx` - inline and full player behavior.
- `design_references/Vocello iOS/screens.jsx` - Voices, History, Settings surfaces.

Open `index.html` in the Codex in-app browser or through a local static server. Interact with every relevant state before editing SwiftUI: switch Studio modes, open pickers, open Settings panels, play previews, generate, dismiss, and expand the inline player.

Do not rely on a single screenshot. Measure the DOM/CSS when layout behavior matters.

## Workflow

1. Pick one surface and one state.

   Write down the exact target states before coding, such as "Studio Custom idle", "Studio Custom complete inline player", "Voice picker open", or "Delete model sheet".

2. Interact with the reference.

   Click through the state changes in the browser, then inspect the relevant component and CSS. For layout measurements, compare positions relative to the app frame, not the browser viewport, because the reference page itself can scroll.

3. Map the reference to native files.

   Common native touch points:

   - Root chrome and global sheet routing: `Sources/iOS/App/RootView.swift`.
   - Bottom dock: `Sources/iOS/App/TabDock.swift`.
   - Studio shell and lower reflow: `Sources/iOS/IOSStudioCanvas.swift`.
   - Studio completion player: `Sources/iOS/Studio/IOSStudioInlinePlayerCard.swift`.
   - Shared visual primitives: `Sources/iOS/IOSDesignSystemPrimitives.swift`.
   - Bottom sheets and full player: `Sources/iOS/Sheets/`.
   - Voices, History, Settings shells: `Sources/iOS/Voices/`, `Sources/iOS/History/`, `Sources/iOS/Settings/`, plus the legacy `Sources/iOS/IOS*.swift` bodies they still wrap.

4. Preserve native behavior while matching visible structure.

   Prefer SwiftUI layout that expresses the same hierarchy as the reference. Avoid absolute overlays for controls that reflow. Use explicit heights only when the reference depends on a fixed state height.

5. Verify in Simulator with the fake backend.

   The Simulator backend is functional for UI review: it can fake model state, generate deterministic WAVs, persist History rows, save voices, and drive the inline player through normal app code paths. Use [`ios-simulator-testing.md`](ios-simulator-testing.md) for launch details.

6. Capture only temporary comparison artifacts.

   Save screenshots and visual notes under `build/Debug/ui-comparison/` or another ignored artifact path. Do not commit screenshot drift into docs unless the maintainer explicitly asks for a permanent visual reference.

## Studio lower layout invariants

These constants came from the reference and should be treated as authoritative unless the prototype changes:

- Tab-dock reservation: `97pt`.
- Compact Studio dock area: `64pt` total (`56pt` CTA/generating/error control + `8pt` bottom padding).
- Complete Studio dock area: `135pt` total (`127pt` inline player + `8pt` bottom padding).
- Inline player card visual height: `127pt`.
- The CTA, generating bar, error control, and inline player keep the same bottom edge above the tab dock.
- The inline player grows upward. The tab dock stays anchored; the composer gives up height; the setup chips and meta/counter row move upward.
- Disabled Generate keeps the reference CTA shape and gradient treatment at reduced opacity. Do not replace it with a generic muted glass button.
- Mode-tinted backdrop and selected-dock tint follow the active Studio mode color. Keep that behavior.

## Sheet and panel invariants

Reference sheets are focus surfaces:

- Blur and dim everything behind a presented panel.
- The panel fills the bottom width inside the phone frame and continues cleanly into the home-indicator area.
- Use the same glass surface family as the reference: dark translucent fill, subtle highlight stroke, soft inner depth, and a visible grabber.
- Close buttons, grabbers, title rows, search fields, filter pills, row heights, and card radii should be measured against the reference state, not guessed from system defaults.
- Voice, Delivery, Reference Clip, Voice Brief, Model Install, Delete Model, Recording, and Player sheets should share the same presentation language.

## Simulator scenario controls

For shell launches, pass env vars with the `SIMCTL_CHILD_` prefix:

```sh
SIMCTL_CHILD_QVOICE_SIM_FAKE_MODELS=all \
SIMCTL_CHILD_QVOICE_SIM_BACKEND_SCENARIO=success \
xcrun simctl launch --terminate-running-process booted com.patricedery.vocello
```

Useful scenarios:

- `QVOICE_SIM_FAKE_MODELS=all` - all Studio models start installed.
- `QVOICE_SIM_FAKE_MODELS=none` - review install onboarding and disabled states.
- `QVOICE_SIM_FAKE_MODELS=custom,design,clone` - seed by mode.
- `QVOICE_SIM_BACKEND_SCENARIO=success` - normal fake generation.
- `QVOICE_SIM_BACKEND_SCENARIO=slow` - long enough to verify Stop/cancel and generating layout.
- `QVOICE_SIM_BACKEND_SCENARIO=fail` - verify error surfaces without saving History.
- `QVOICE_SIM_BACKEND_DELAY_MS=<milliseconds>` - override the fake generation delay.
- `QVOICE_SIM_SEED_DATA=history,voices` - seed reviewable History and Saved Voice fixtures.

For XcodeBuildMCP simulator launches, pass the same env names through the launch tool's `env` dictionary. Do not leave `QVOICE_SIM_BACKEND_SCENARIO=fail` active after failure testing; relaunch with `success` or no scenario before taking normal screenshots.

## Verification checklist

Run these before handing off a reference-match change:

```sh
./scripts/check_project_inputs.sh
git diff --check
./scripts/build_foundation_targets.sh ios
```

Then launch `VocelloiOS` on iPhone 17 Pro Simulator and compare the affected native states against the browser reference. For Studio work, capture at least:

- Custom idle Generate.
- Custom generating.
- Custom complete inline player.
- Design disabled Generate.
- Any sheet or picker touched by the change.

Acceptance checks:

- No persistent global now-playing rail appears in normal chrome.
- Tab dock stays anchored and does not overlap CTA, inline player, sheets, or tab content.
- Studio completion reflows by shrinking the composer, not by moving the dock.
- Simulator generation uses the fake backend and normal persistence/player paths, not one-off screen mocks.
- Production defaults and real device backend behavior remain unchanged.

## Common pitfalls

- Browser screenshots can be misleading after the page scrolls. Measure app-relative positions.
- Do not copy prototype demo text into production default state.
- Do not add UI-only Simulator mocks inside the front-end when the fake backend can exercise the real path.
- Do not move iOS resources in `project.yml`; keep the XcodeGen resource workaround documented in `CLAUDE.md`.
- Do not commit generated screenshots or simulator data.
