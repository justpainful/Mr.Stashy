# Stashy Product Roadmap

## Shipped in this pass

- Original `Bookmark` and `Archive Card` character pair, used only as transparent in-app illustrations.
- Illustrated empty states for Catch, Queue, and Library.
- Living Post opens as a resizable sheet from Library, with a source-aware presentation tint rather than a generic archive page.
- Local media cards support long press for Save to Photos and Share, alongside their visible actions.

## Small and medium improvements

These are safe to continue without changing the product boundary:

1. Collections and pinned posts in the offline library.
2. Native search suggestions for people, saved text, and media type.
3. A compact media inspector for dimensions, codec, checksum, and original-source status.
4. Contextual Tips that teach paste, long press, and local export once, then stay out of the way.
5. App Intents for opening Catch, Queue, and a selected saved post from Shortcuts and Siri.
6. Optional local notifications for completed or failed queue jobs.

## Large decisions that need approval first

1. **Additional live platform support.** This needs official contracts or user-provided, lawful source access. Stashy must not claim that a platform works until a live contract proves it.
2. **Account-linked source imports.** This changes the privacy and security model, needs token storage, consent UX, revocation, and a privacy-policy update.
3. **Cloud sync or shared libraries.** The app is currently local-first. Adding sync changes storage, encryption, conflict handling, and the product promise.
4. **Collaborative collections / SharePlay.** This adds a social model rather than a private archive feature.

## Design rules

- The source presentation may borrow a platform's color language, but always remains visibly Stashy: no copied source UI, logos, or implication of an official partnership.
- Every downloaded asset stays locally inspectable and exportable.
- Characters are supporting illustrations, never required to understand an action and never used as a fake loading state.
