# Resolver architecture

## Contract

Each resolver conforms to `PlatformResolver`: it declares a platform, decides whether it can handle a canonical URL, and resolves to a `ResolvedPost`. The result preserves the original and canonical URLs, author snapshot, text, quoted content, ordered media, variants, quality labels, and resolver version.

`URLCanonicalizer` normalizes host casing, HTTPS, and tracking fragments/parameters before resolver selection. `DirectMediaResolver` handles clear public image, video, GIF, and audio URLs. Platform-specific resolution must be added behind its own resolver and live contract coverage; a generic metadata scrape alone is not sufficient evidence of full platform support.

## Verification policy

A contract result must verify, at minimum:

- public/authorized access without a user-account bypass;
- all media items and source order for a mixed-media fixture;
- expected text/author fields where publicly exposed;
- a usable original/highest exposed variant attempt;
- media MIME/signature integrity so an HTML error page cannot be archived;
- redacted log output and no credentials in fixture data.

The suite writes `Artifacts/PlatformSupportReport.json`. `scripts/validate_support_report.py` validates its schema and renders `Artifacts/PlatformSupport.md`; the generated Swift capability registry must use this evidence. Required platforms must be `passing` for a release. YouTube is production-visible only if it passes independently.

## Safety boundaries

Resolvers must not bypass DRM, encryption, paywalls, private posts, rate limits, or authentication controls. They must not manipulate watermarks. If the clean source is not exposed publicly, the resolver reports that state rather than fabricating a result.
