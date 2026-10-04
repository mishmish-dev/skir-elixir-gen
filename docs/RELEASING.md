# Releases

The npm generator `skir-elixir-gen` and Hex runtime `skir` share version `0.3.0`.
They remain unpublished until a stable GitHub release is published.
Both registries publish **public packages**, even while this GitHub repository
is private. Publishing discloses the packaged source and documentation.

## Credentials (one-time setup)

Add these repository secrets in GitHub Settings → Secrets and variables → Actions:

- `npm_token`: an npm **granular** token with permission to publish
  `skir-elixir-gen` and bypass 2FA enabled for automated publishing. Configure
  package access on the publishing account and rotate the token before expiry.
- `HEX_API_KEY`: a Hex API key with package-write permission for `skir`.
  The publishing account must own the package after the first publication.

The workflow fails with a clear error if its credential is absent. Credentials
are only available to publication steps, never PR checks. Do not commit tokens.
See [npm's CI documentation](https://docs.npmjs.com/using-private-packages-in-a-ci-cd-workflow/)
and [Hex publication instructions](https://hex.hexdocs.pm/Mix.Tasks.Hex.Publish.html).
The names were unclaimed when checked on 2026-10-04; availability can change.

## Validate and release

1. Set the same version in `package.json` and `runtime/mix.exs`. Update the npm
   lockfile with `npm install --package-lock-only --ignore-scripts` and commit.
2. Run `npm ci --ignore-scripts`, initialize Hex/Rebar, and run `npm run test:all`.
   This includes lint/format checks, 90% minimum native coverage, both oracles,
   npm publication dry-run, local Hex build checks, and a fresh consumer install of both tarballs.
3. Optionally run the **Release** workflow manually on the intended commit.
   Manual runs execute the complete OTP 27/28/29 matrix and **never publish**.
4. Create a stable GitHub release tagged `vX.Y.Z` at that commit and publish it.
   Drafts and prereleases do not publish packages; mismatched tags fail early.
   The release reruns the full matrix at the tag before either registry upload.

npm publishes the exact tarball retained by the OTP 29 checks. Hex rebuilds the
validated runtime from the same tag using the committed production dependency
lockfile and publishes the package without HexDocs. API usage documentation is
included in the package README; generating hosted HexDocs can be added later.
CI artifacts retain both distributable tarballs and the coverage/reference data.
Hex 2.5.1 requests authentication even for `hex.publish --dry-run`, so ordinary
CI uses `hex.build` and an isolated consumer install. The authenticated release
step also performs the Hex publication dry-run before uploading.

npm and Hex publication jobs are independent. If one upload succeeds and the
other fails, fix its credential or registry issue and **re-run failed jobs** on
the same release run. Do not rerun the successful job: registries generally
reject republishing an existing version. Never overwrite a released version;
substantive fixes require a new version and tag.
