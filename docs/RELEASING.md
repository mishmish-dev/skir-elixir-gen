# Generator releases

This repository publishes only `skir-elixir-gen` to npm. The companion
[client package](https://hex.pm/packages/skir_elixir_client) is published to Hex
by its own repository and has an independent version. The example and CI use
`skir_elixir_client` 0.2.1 from Hex, selected by `example/mix.lock`. The requirement
in `example/mix.exs` permits compatible 0.2.x patch releases. No client checkout
or deploy key is required.

## Automatic releases

Configure a GitHub Actions trusted publisher in the npm package settings:

- Organization or user: `mishmish-dev`
- Repository: `skir-elixir-gen`
- Workflow filename: `release.yml`
- Environment name: leave blank (the workflow does not use a GitHub environment)
- Allowed actions: enable direct publishing with `npm publish`

The publish job uses GitHub OIDC (`id-token: write`), Node 24 and the latest npm
CLI. It requires no npm publishing token or repository secret. See
[npm trusted publishing](https://docs.npmjs.com/trusted-publishers/).

1. Set `package.json` version and update `package-lock.json`. When changing the
   compatible runtime baseline, update the dependency requirement in `example/mix.exs`
   and regenerate `example/mix.lock`.
2. Run `npm ci --ignore-scripts`, initialize Hex/Rebar and run `npm run test:all`
   and `npm run test:benchmark`. Review the malformed-input and OTP release
   benchmark reports under `.artifacts/` and the current [security findings](SECURITY_REVIEW.md).
   Runtime fixes must be adopted through the Hex dependency and verified with
   the generator; production adoption also needs application deployment checks.
3. Push the commit to `main`. The Release workflow compares the version with
   the latest release tag and publishes a changed version after the full CI gate.
4. After npm publication succeeds, CI creates `vX.Y.Z` and a GitHub release
   pointing to the published commit.

CI tests Elixir 1.18.4 / OTP 27 and Elixir 1.20.4 / OTP 27, 28 and 29. It publishes
exactly the tested npm archive from the Elixir 1.20.4 / OTP 29 job. Manual workflow
dispatch from `main` follows the same version check and can publish a changed
version. Other branches do not trigger automatic releases.

The version must be stable `X.Y.Z`. npm archives are public. Never republish an
existing version. If npm authentication fails, check the trusted publisher's
repository, workflow filename and direct-publish permission, then rerun the
failed job. If npm succeeds but
GitHub release creation fails, rerun only that job so the package is not uploaded
again.

## Production adoption

Run the full gate and release benchmark with your application's schemas on the
Elixir/OTP versions you intend to deploy. Reference serialization checks target
the shared wire format; a specific client language is not a release requirement.
Benchmark results describe the measured machine and codec workloads, not a
production throughput guarantee. See [verification scope](../VERIFICATION.md)
and the [security review](SECURITY_REVIEW.md) for limits and open runtime findings.

`package-lock.json` and `example/mix.lock` are tracked. Keep them synchronized
with dependency changes, and install with `npm ci --ignore-scripts` and
`mix deps.get --check-locked`. npm dependencies use caret ranges; Mix requirements
use equivalent bounds (`~> 0.2.1` for patch updates and `~> 2.9` for minor updates).
The generator and runtime publish independently; adopting runtime fixes requires
updating the example's Hex lockfile, adjusting its dependency requirement when
needed, and rerunning the generator gate.

## Initial release

Version 0.1.0 was published manually and tagged after publication. Subsequent
releases use CI: bump the npm version, run the checks and push to `main`.
Do not attempt to publish 0.1.0 again. The initial split tested the independently
published Hex runtime 0.2.0.
