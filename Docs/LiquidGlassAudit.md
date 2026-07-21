# Liquid Glass audit

## Intentional surfaces

The iOS 26 design system uses native SwiftUI Liquid Glass APIs rather than material overlays:

| Surface | API | Interactive | Rationale |
| --- | --- | --- | --- |
| Compact Catch action bar | `GlassEffectContainer`, `.glassEffect`, `.buttonStyle(.glass/.glassProminent)` | Buttons only | Groups paste/resolve actions without turning content into a glass card wall |
| Result-ready row | `.glassEffect(... .interactive())` | Yes | Indicates the row opens detected results |
| Status pills | `.glassEffect` on capsule | No | Compact status context; the pill itself is not a control |

Glass is applied after layout/padding and related controls are grouped in `GlassEffectContainer`. Content, archive rows, illustration reserves, and large reading surfaces remain flat/graphic.

## Prohibited implementation

Production UI must not use `.thinMaterial`, `.ultraThinMaterial`, `.regularMaterial`, fake blur rectangles, or a custom material substitute. The deployment target is iOS 26; if a tool/previews need a guard, use an opaque fallback rather than fake glass.

## Verification still required

The above is a source inventory, not simulator QA. Before release, verify light/dark, Reduce Transparency, large type, Arabic RTL, and touch behavior on the actual target simulator; record screenshot paths and any fixes in `VisualQA.md`.
