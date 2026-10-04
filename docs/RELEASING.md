# Generator releases

This repository publishes only `skir-elixir-gen` to npm. The companion
[client package](https://hex.pm/packages/skir_elixir_client) is published to Hex
by its own repository and has an independent version. The example and CI use
exactly `skir_elixir_client` 0.2.0 from Hex, pinned in `example/mix.exs` and
`example/mix.lock`. No client checkout or deploy key is required.

## Automatic releases

Set the repository Actions secret `npm_token` to an npm token authorized to
publish `skir-elixir-gen` without an interactive two-factor prompt.

1. Set `package.json` version and update `package-lock.json`. When changing the
   compatible runtime baseline, update the exact dependency in `example/mix.exs`
   and regenerate `example/mix.lock`.
2. Run `npm ci --ignore-scripts`, initialize Hex/Rebar and run `npm run test:all`.
3. Push the commit to `main`. The Release workflow compares the version with
   the latest release tag and publishes a changed version after the full CI gate.
4. After npm publication succeeds, CI creates `vX.Y.Z` and a GitHub release
   pointing to the published commit.

CI tests Elixir 1.18.4 / OTP 27 and Elixir 1.20.4 / OTP 27, 28 and 29. It publishes
exactly the tested npm archive from the Elixir 1.20.4 / OTP 29 job. Manual workflow
dispatch from `main` follows the same version check and can publish a changed
version. Other branches do not trigger automatic releases.

The version must be stable `X.Y.Z`. An absent publishing token fails with a clear
error. Registry publication makes the archive public even while the source
repository is private. Never republish an existing version. If npm fails, fix
the credentials or registry issue and rerun the failed job. If npm succeeds but
GitHub release creation fails, rerun only that job so the package is not uploaded
again.

## Manual first release: v0.1.0

The initial generator version is 0.1.0; its tested runtime is Hex 0.2.0.
From the release checkout, on Node 20+, Elixir 1.18+ and OTP 27+:

```sh
npm ci --ignore-scripts
mix local.hex --force
mix local.rebar --force
npm run test:all
npm login --registry=https://registry.npmjs.org
npm publish ./.artifacts/packages/skir-elixir-gen-0.1.0.tgz --ignore-scripts --access public
npm view skir-elixir-gen@0.1.0 version dist.integrity
```

Commit the tested release changes before publishing. After confirming npm
publication, create the matching `v0.1.0` tag and GitHub release at that commit.
Push the tag with the commit so the automatic workflow sees the published
version and skips another npm upload. Subsequent releases use the automatic
workflow above.
