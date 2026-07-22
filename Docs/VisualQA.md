# Visual QA

## Latest automated review

Reviewed from CI run `29965874922`, job `89077292782`, on iPhone 17 Pro Max (iOS 26.5). The `ui-test-results` artifact contains the complete named screenshot set.

| Check | Required final evidence | Status |
| --- | --- | --- |
| Device | Current iPhone Pro Max simulator and closest available iPhone 14 Pro Max | iPhone 17 Pro Max passed; iPhone 14 baseline remains release-only |
| Locale | English and Arabic RTL | Passed; Arabic Catch and Library reviewed in RTL |
| Appearance | Light and warm charcoal dark | Passed for captured light and dark flows |
| Text size | Standard and large accessibility size | Pending final run |
| Screens | All 14 required screenshot flows | Passed; 14 non-empty PNGs in the UI artifact |
| Artwork treatment | Character and illustration assets are intentionally not used per the current product direction | Passed; reviewed screens use native controls and SF Symbols only |

The screenshot harness requires these final paths: `Artifacts/Screenshots/onboarding.png`, `catch-empty.png`, `results-mixed-media.png`, `queue.png`, `library-posts.png`, `library-media.png`, `living-post.png`, `text-card-composer.png`, `settings.png`, `discord-disabled.png`, `ar-catch.png`, `ar-library.png`, `dark-catch.png`, and `dark-library.png`.

## Findings

- The text-card canvas was incorrectly constrained to 86 points wide after removal of the broken artwork surface. It now fills the 1080×1350 export canvas; the corrected preview was reviewed in `text-card-composer.png`.
- Results preserve all three fixture media items in source order and show type, dimensions, duration where applicable, codec, container, size, and cleanliness.
- Arabic Catch uses true RTL layout. Dark Library preserves readable contrast and native tab treatment.
- No character or illustration asset appears in the reviewed runtime screens.
- Large accessibility text and the closest iPhone 14 Pro Max baseline are still reserved for the release workflow and are not claimed by this PR audit.
