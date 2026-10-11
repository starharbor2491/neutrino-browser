# Optional AI

AI stays off until configured. API keys and account credentials live in macOS Keychain, not SQLite or exported setups. BYOK requests use the provider's official HTTPS host; local compatible endpoints may use HTTP only on loopback. Redirects are refused and responses are bounded.

The assistant sends the question plus explicitly selected page text, selected text, or Space tab titles/addresses. Organization results are bounded folder proposals referencing known tab IDs; they cannot navigate, submit forms, or execute tools. Application requires a separate user action and an unchanged Space snapshot.

## OpenAI account flow

The source follows OpenAI's documented own-client OSS dynamic registration:

- [Open-source token sharing](https://developers.openai.com/siwc/token-sharing-open-source)
- [Sign-in](https://developers.openai.com/siwc/sign-in)
- [Profiles and sessions](https://developers.openai.com/siwc/profiles-and-sessions)
- [Models and inference](https://developers.openai.com/siwc/models-and-inference)

Neutrino supplies its own name and stable host identity, retains the issued client ID, and uses PKCE/state/nonce with a bounded 127.0.0.1 callback. Identity verification checks the fixed issuer's RSA signature, audience/authorized party, subject, nonce, dates, and optional access-token hash. Refresh validates returned identities and cannot resurrect a cancelled/disconnected connection. Model discovery uses the account's catalog; inference uses the public Responses API with `store: false` and requires completion.

Portable tests verify claim validation boundaries. Native sign-in, Keychain storage, refresh/revocation, model discovery, and inference have not been exercised with an actual account here. Protocol source is not account acceptance.

## xAI

API keys are implemented. Account OAuth remains gated on supported Neutrino client registration and inference entitlement. Another application's client identity must never be borrowed to claim support.
