# Discord bot-token tools

Discord tools are conditional and must be disabled unless a user explicitly configures a **bot token**.

## Allowed

- A user provides a token created for a bot they control.
- The app stores the token in Keychain, scopes requests to the bot API, and redacts it from UI, diagnostics, exports, and logs.
- The app clearly explains its requested capability before the token is used.

## Forbidden

- Personal Discord user tokens, self-bot automation, embedded credentials, account scraping, or bypassing Discord permissions.
- Sending a token to a Stashy service or putting it in GitHub Actions secrets unless a separately reviewed, authorized bot-integration test requires it.

Settings and screenshot coverage must show an explicit disabled state when no valid bot token is stored.
