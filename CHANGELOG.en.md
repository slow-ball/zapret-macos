# Changes

## 1.0.1

- **Smart mode knows blocked sites in advance.** The community's list is refreshed on the Mac every day — such
  sites open from the first visit, and the engine notices new blocks at the second failure
- **YouTube video goes over QUIC, as the browser picks.** "YouTube video over TCP" is now off by default: turn
  it on if 4K stutters
- **An upload check.** The provider may freeze uploads to foreign sites the bypass hides along with the blocked
  ones — after ~16 KB. Checks notice it and say what to do
- **Telegram works again where the provider closed its addresses.** A recent macOS sends a big TLS hello, and
  some providers break such connections to Cloudflare — the proxy couldn't reach the relays. Now it talks to
  them in a way that gets through; Telegram's own encryption inside is unchanged
- **An honest Telegram status.** The proxy notes whether it reaches Telegram. When it doesn't, the app says so
  and offers Fix, autofix refreshes the relays and restarts the proxy, and Checks shows which ways are closed:
  Telegram's addresses, the relays, the data center
- **Telegram connects at once.** The proxy remembers the way it reached Telegram — after sleep, a new network or
  an update it goes that way right away, without waiting on closed addresses
- **A quick start of the adaptive strategy.** Right after an install, a reset or switching to the adaptive
  strategy, YouTube and Discord get a working trick within a minute — no waiting until the engine has seen
  enough failures

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
