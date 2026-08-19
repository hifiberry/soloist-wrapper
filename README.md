# hifiberry-soloist-wrapper

Runs Spotify Soloist as a Spotify Connect endpoint on HiFiBerryOS and
bridges its local WebSocket API to audiocontrol, providing metadata,
artwork, queue and transport control through the same interface every
other player uses.

This package does not contain the Spotify Soloist binary, which may not be
redistributed. It is downloaded from Spotify on first use (`soloist-fetch`),
and each user must supply their own Soloist API key from the Spotify for
Developers dashboard, entered through the WebUI and stored in ConfigDB. A
Spotify Premium account is required.

## Known limitations

- **No outbound HTTPS, no Soloist.** `soloist-fetch` downloads the Soloist
  binary from Spotify's CDN over HTTPS on first install, and the installed
  build stops authenticating 90 days after it was fetched unless
  `soloist-update` can reach the same CDN to refresh it. A device without
  outbound HTTPS access can therefore neither install Soloist nor keep an
  existing install working past that 90-day window.
- **The API key is visible in `/proc/<pid>/cmdline`.** Soloist takes its API
  key only as a command-line argument (`start-soloist`'s only input path for
  it), so any local user who can read `/proc/<pid>/cmdline` for the running
  `soloist` process can recover the key. This is a documented, accepted
  risk, not a bug: the key is never written to a service unit, environment
  file, or log, and the local-user threat model is the same one every other
  process-argument secret on the device already accepts.
- **Volume is not synchronised between Spotify and the device mixer.**
  `soloist-bridge` deliberately drops Soloist's `volume_changed` events and
  never issues a `set_volume` command (see the bridge's command
  translation). The device volume is pinned once, at startup, by
  `start-soloist --initial-volume 100`; remote volume changes made from the
  Spotify app move Soloist's internal attenuation but are not reflected
  back to ACR or the device mixer. See the spec's "Volume reconciliation"
  section for why forwarding was considered and rejected (Spotify's app
  slider is quantised to 16 steps, coarser than ACR's own range, and
  correct forwarding would need a reset-to-100 echo-suppression loop).
- **`/api/soloist/command` does not 404.** No nginx location proxies it, so an
  unmatched request falls through to the WebUI SPA's catch-all: `GET` answers
  200 with the app's `index.html`, `POST` answers 405. It never reaches
  audiocontrol's private transport channel regardless -- there is no
  `proxy_pass` for it at all, and `/etc/hifiberry/auth.d/soloist-auth.json`'s
  `default_tier` independently classifies anything under `/api/soloist` not
  explicitly listed as `ok` as `risky`. Safety here does not rest on the
  status code being 404; confirmed on a real device (Task 7).
- **`apt remove` does not remove the player from the WebUI.** debhelper
  registers every file this package installs under `/etc/` as a conffile, so
  a plain `apt remove hifiberry-soloist-wrapper` leaves the ACR, WebUI,
  auth-tier and config-server descriptors in place and the Soloist card
  keeps showing in the WebUI. `apt purge` removes them. This is standard
  Debian/debhelper conffile semantics, applied the same way across this
  project, not a bug specific to this package -- it is intentionally left
  as-is rather than special-cased. Either way, the downloaded Soloist binary
  and the paired Spotify session under `$HOME` survive, which *is*
  intended: reinstalling (after `remove` or `purge`) must not force
  re-pairing.
