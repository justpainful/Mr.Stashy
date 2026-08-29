# Stashy — design brief (locked before code)

## 1. Subject
Stashy is an iPhone app that takes a public post link (TikTok, YouTube, X, Instagram, Reddit,
Bluesky, Pinterest, Snapchat, Kick, Threads, Tumblr, Imgur, Discord, or a direct file) and
stores the post — text, author, every image, the video at the highest real quality the source
serves — on the phone, offline, with no account. The one job of the main screen is: paste a link,
see exactly what will be saved, save it.

## 2. Vernacular (the only legitimate source of design decisions)
Archive boxes and index cards; file sizes in MB; resolutions (720p / 1080p / 4K); codec names
(H.264, AV1, AAC); progress in bytes; "verified" checksums; platform brand colours (TikTok
black/cyan/red, YouTube red, Bluesky blue, Kick green, Snapchat yellow, Reddit orange); the
"stash" as a hoard kept in a drawer.

## 3. Palette
| name | hex | why |
|---|---|---|
| ink | `#15171A` | text; the black of a label-maker strip on an archive box |
| paper | `#F4F1EB` | light background; kraft/index-card paper, not pure white |
| paper-dark | `#0F1113` | dark background; the app mostly shows video and photos, so dark mode is justified (Tier 1) |
| card | `#FFFFFF` / `#1A1D21` | raised surfaces |
| stash amber | `#C9741C` | the single accent: the colour of a kraft box tab / rubber band. Buttons, selection, progress |
| verified green | `#2F7D4E` | a file that downloaded and hashed correctly |
| warn red | `#B42B1E` | a source that could not be captured |
| muted | `#6E7379` | secondary text, spec lines |

Platform colours appear only as the small glyph tint next to a post, never as a gradient.

## 4. Type
- Display and body: the system font (SF Pro / SF Arabic). On iPhone this is the platform's own
  face, not a generator default; Arabic gets SF Arabic automatically with correct shaping.
- Utility ("spec lines": `1080p · H.264 · 24.3 MB`): system monospaced digits
  (`.monospacedDigit()`), so sizes and resolutions line up in lists.
- Scale: 34 large title, 22 section, 17 body, 15 secondary, 13 spec. Arabic line height is
  left to the system (it already uses 1.7–1.8 for SF Arabic); no letter-spacing anywhere.

## 5. Signature
**The spec line.** Every media item — in the preview, the queue and the library — carries a
compact monospaced line that states what was actually captured: resolution, codec, size, and a
green "verified" mark once the file is hashed. It is the one element that could not be copied
into another app: it is the product's honesty made visible. Everything around it is quiet.

## Deliberately not used
No gradients, no glass cards over gradients, no mascots in the runtime UI, no "Supercharge"
copy, no three-feature-card grids, no fake previews. Empty states are one sentence and one
action.
