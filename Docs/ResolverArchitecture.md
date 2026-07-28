# Resolver architecture

## Contract

Each resolver conforms to `PlatformResolver`: it declares a platform, decides whether it can handle a canonical URL, and resolves to a `ResolvedPost`. The result preserves the original and canonical URLs, author snapshot, text, quoted content, ordered media, variants, quality labels, resolver version, and any warnings the person needs to see.

`URLCanonicalizer` normalizes host casing, HTTPS, and tracking parameters before resolver selection. It deliberately keeps parameters that carry a post identifier — a YouTube `v` or a Kick `clip` — because stripping them turned a valid link into an unresolvable one. `DirectMediaResolver` handles clear public image, video, GIF, and audio URLs; a platform page that merely ends in a media extension is still a platform page.

## The pipeline

```text
canonicalize → expand short link → select resolver
                                        ↓
              source's own endpoint (oEmbed / syndication / widget / clip API)
                                        ↓  (when that yields nothing)
              page fetch, retried across fetch profiles
                                        ↓
   extract: Open Graph + Twitter cards → JSON-LD → inline elements → inline JSON
                                        ↓
                 confirm each candidate actually serves media
                                        ↓
                  ordered ResolvedPost, with warnings for gaps
```

### Fetch profiles

Open Graph, oEmbed, and JSON-LD exist so a link-preview crawler can read metadata a page already publishes, and the large platforms only render that metadata when the request looks like a preview crawler. A few render their post payload only for a browser. `FetchProfile` therefore has three identities and `PageFetcher` retries across them until an extractor is satisfied.

This is not incidental. A single hard-coded agent is why the app previously could not read most of its own advertised sources: TikTok and Imgur answer an unrecognised agent with a JavaScript shell that contains no `og:` tags at all, so ten of eleven sources terminated in "No media was found" on perfectly public posts.

No profile sends cookies, stored credentials, or private-session headers, and none is used until a person has explicitly asked Stashy to inspect that link.

### Confirmation before offering

`MediaProbing` reads the first bytes of each candidate address before it is offered as savable. This stops three distinct failures:

- a source that answers `200 text/html` for a media address, which would otherwise be archived as the post;
- a `Content-Type` that contradicts the file extension, which would otherwise be verified against the wrong signature;
- an address that is simply no longer served, which would otherwise fail late, after the person believed the post was archived.

A confirmed length also becomes the download size the queue displays, which is why the queue can show a real total and time remaining.

Unit tests inject `PassthroughMediaProber` so they stay deterministic and offline; `ResolverRegistry` builds production resolvers with `URLSessionMediaProber`.

### What is never treated as media

- HTML embed players. `og:video` is frequently a player page rather than a file; those are recognised by declared type or by an `/embed/`, `/player`, or `/iframe` path.
- Adaptive-stream manifests (`.m3u8`, `.mpd`). Stashy archives files; a manifest is a playlist, and archiving one would put a few kilobytes of text into the archive under the name of the video.
- A page's own share card or logo, when the page published nothing else. That case is recorded as a warning rather than presented as the post.

### Saying why

A login or consent wall answers with HTTP 200, so a status code alone cannot explain why a public-looking link produced nothing. `AccessWallDetector` distinguishes an account requirement from a private post and from a deleted one, and every `ResolverError` carries recovery guidance so a failure names what to do next.

## Capability reporting

`PlatformCapabilityRegistry.baseline` states, next to the resolvers it describes, what each adapter can and cannot do. `SupportStatus` distinguishes `passing`, `limited` (the source publishes less than a full post — a cover image, a poster frame), and `needsCredential` (the source requires access the reader does not have). Collapsing those into "works" or "does not work" is what previously made a working capture look like a failure.

The Catch screen is built from this registry, so the picker cannot advertise a source with no working adapter, and cannot hide one that works.

## Verification policy

A live contract result must verify, at minimum:

- public/authorized access without a user-account bypass;
- all media items and source order for a mixed-media fixture;
- expected text/author fields where publicly exposed;
- a usable original/highest exposed variant attempt;
- media MIME/signature integrity so an HTML error page cannot be archived;
- redacted log output and no credentials in fixture data.

`LivePlatformContractTests` runs only when `LIVE_PLATFORM_CONTRACTS=1` reaches the *test process*. `xcodebuild` does not forward the host environment into that process, so `scripts/platform_contracts.sh` injects it through the `TEST_RUNNER_` prefix; setting it directly on `xcodebuild` meant the "live" contracts previously ran entirely offline and could not fail.

The suite writes `Artifacts/PlatformSupportReport.json`, which `scripts/validate_support_report.py` validates and renders. `PlatformContractEvidence` is generated from it and may **narrow** the shipped baseline — a source proven broken is demoted — but may never widen it. A result recorded from a data centre is a diagnostic, not a verdict about a phone: several sources answer a hosted runner differently from a residential connection.

## Owner-supplied access

A person who owns developer access to a source can add their own key under `Settings → Your source access`. Keys are held in the device Keychain and never written to settings, manifests, archives, diagnostics, or logs. `MediaVariant.safeArchiveCopy` strips credential headers and signed query strings before anything reaches a manifest.

## Safety boundaries

Resolvers must not bypass DRM, encryption, paywalls, private posts, rate limits, or authentication controls. They must not manipulate watermarks. If the clean source is not exposed publicly, the resolver reports that state rather than fabricating a result.
