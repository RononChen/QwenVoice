# iOS UI visual references

These PNGs are known-good content references for canonical Vocello iPhone states. They are not
pixel-equality gates because current evidence is captured through bundled Computer Use and iPhone
Mirroring, whose window chrome and scaling may differ.

Use `$vocello-ios-ui-qa full` to reach Studio Custom/Design/Clone, the voice sheet, Settings,
History, and Voices. Save current screenshots under `build/ios/agent-ui/<run>/screenshots/`, compare
content semantically, and record findings in the report.

Update a reference only when the UI change is intentional and separately reviewed. Never crop or
transform a live screenshot merely to force a match.

The iOS Simulator is not used. Computer Use must operate a paired physical iPhone through iPhone
Mirroring; scripts validate device telemetry separately.
