# Gamebox Design Tokens

`tokens/gamebox.tokens.json` is the only hand-edited source for shared numeric design values. The schema, generated Dart file, generated GDScript file, prose, and tests are consumers; do not copy a token value into another source without registering the semantic JSON path below.

## Workflow

Regenerate both platform mappings from the repository root:

```bash
dart tool/generate_design_tokens.dart \
  --input design_system/tokens/gamebox.tokens.json \
  --dart-output app/lib/design_system/generated/gamebox_tokens.g.dart \
  --godot-output game_runtime/design_system/generated/gamebox_tokens.gd
```

The generator resolves the canonical document's `$schema` path, validates the instance against that schema with the repository's fail-closed validator, strictly parses the token contract, and then writes both mappings. It has no network dependency.

Check schema conformance, parser behavior, generated-file drift, normative claims, and production hard-coded style additions with:

```bash
bash tool/verify_design_system.sh
```

## Versioning

- Removing or renaming a token, or changing a public interaction meaning, increments the major version and requires migration guidance.
- Adding a compatible role or changing a locked token value increments at least the minor version and regenerates both mappings.
- Fixing generator implementation without changing generated output or its public interface increments the patch version.

## Normative numeric-claim registry

The verifier scans the UX references, retrofit plan, this README, and design-system tests for dimension or duration literals. A `claim` entry binds a prose literal to a canonical JSON path; the verifier reads the expected value from JSON. An `exception` entry must identify a non-token standard, viewport, gameplay, or runtime-coordinate value. Registry comments themselves are excluded from the scan.

<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/ux-standard.md | 4 | dp | spacing.base -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/ux-standard.md | 8 | dp | spacing.layout -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/ux-standard.md | 16 | dp | component.pagePadding -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/ux-standard.md | 24 | dp | component.sectionSpacing -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/ux-standard.md | 48 | dp | component.minimumTouchTarget -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/flutter-app.md | 48 | dp | component.minimumTouchTarget -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/godot-games.md | 48 | dp | component.minimumTouchTarget -->
<!-- gamebox-numeric-claim: .agents/skills/gamebox-material-3-ux/references/acceptance.md | 48 | dp | component.minimumTouchTarget -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 8 | dp | shape.input -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 12 | dp | shape.card -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 16 | dp | shape.floating -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 20 | dp | component.smallProgressSize -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 28 | dp | shape.dialog -->
<!-- gamebox-numeric-claim: docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md | 48 | dp | component.minimumTouchTarget -->

## Registered non-token numbers

The following values are intentionally not design tokens and must not be generalized into public styling values:

- semantic-version examples and the initial design-system version;
- the locked Flutter/Dart release and color-scheme API provenance, including its fixed neutral contrast argument;
- Android phone viewport sizes used by tests and screenshot evidence;
- Gomoku board dimensions, design canvas, runtime scale, scene coordinates, and grid geometry;
- workflow counts, requirement ranges, test counts, line references, and protocol/version identifiers.

If a future scanned dimension or duration is genuinely one of these categories, add a path-specific `gamebox-numeric-exception` comment with a stable reason identifier. Do not add a reusable color or style allowlist.
