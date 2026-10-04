# Generator releases

This repository publishes only `skir-elixir-gen` to npm. The companion
[client repository](https://github.com/mishmish-dev/skir-elixir-client) owns Hex
publication and has an independent version.

Repository Actions secrets:

- `npm_token`: npm publishing token for `skir-elixir-gen`.
- `SKIR_ELIXIR_CLIENT_DEPLOY_KEY`: read-only SSH deploy key for the private client.
  Tests check out exactly the commit stored in `.client-revision`.

To release:

1. Set `package.json` version and update `package-lock.json`. Update the client
   revision explicitly when changing the compatible runtime baseline.
2. Run `npm ci --ignore-scripts`, initialize Hex/Rebar and run `npm run test:all`
   with the pinned client checked out as a sibling.
3. Optionally dispatch the Release workflow; it validates all three OTP entries
   and never publishes during manual runs.
4. Publish a stable GitHub release tagged `vX.Y.Z` matching `package.json`.
   The release reruns CI, then publishes the exact npm archive from OTP 29.

Drafts and prereleases do not publish. An absent publishing token fails with a
clear error. Registry publication makes the archive public even if the source
repository is private. Never overwrite a published version. If publication
fails, fix the credential or registry issue and rerun the failed job.
