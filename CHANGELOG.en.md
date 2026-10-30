# Changes

## 1.0.1

- **Telegram works again where the provider closed its addresses.** A recent macOS sends a big TLS hello, and
  some providers break such connections to Cloudflare — the proxy couldn't reach the relays. Now it talks to
  them in a way that gets through; Telegram's own encryption inside is unchanged

## 1.0.0

The first release of zapret for macOS as an app of its own, with its own engine.

- **The adaptive strategy.** A ladder of tricks in the engine itself: every site has its own trick, and on a
  break the site moves to the next one at once. Separate ladders for QUIC and Discord voice
- **Live choice.** The engine measures the speed the browser gets, tries other tricks on a share of
  connections and moves the site to a clearly faster one. Every group of YouTube's video servers has its own rung
- **It learns by itself.** Once a day the best trick goes first, and the generator replaces the bad ones with new ones
- **Smart mode.** Only sites that don't open without a bypass are handled; the engine sees the provider's
  resets and block pages in the incoming packets
- **Its own Telegram proxy** — no Python: Telegram's web servers, relays on Cloudflare, direct
- **Its own fake packets** — ClientHello, QUIC Initial and STUN are built from the project's sources
- **DNS for neural networks**, the "A site doesn't open?" check, the deep search, the game filter
- **The app**: home, strategies, the Adaptation page, sites, checks, journal, settings; the menu bar panel,
  a widget, ⌃⌥Z
- **It looks after itself**: autofix, fresh strategies every day, updates only with signed versions
