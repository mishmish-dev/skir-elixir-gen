> Historical implementation notes from before the client repository split.
> For current ownership and commands, see README.md and docs/RELEASING.md.

# Release and CI completion

User-approved scope: fix the five CI/release gaps identified in the comparison
with upstream generators. Prepare publication; do not publish a package now.

## Tasks

1. Commit npm and both Mix lockfiles; use npm ci and locked Mix fetches.
2. Add ESLint, Prettier and native Mix format checks for handwritten code.
   Preserve generated output and the unmodified upstream golden schema.
3. Add one packed-package consumer smoke test: install the actual npm tarball,
   generate with the real compiler, compile against the packaged Hex runtime,
   and round-trip a value. Run npm publication dry-run and Hex build checks in CI.
   Run Hex publication dry-run in the authenticated release step.
4. Add a release workflow that reuses the complete three-OTP CI gate, checks
   release tag/version consistency, and publishes npm and Hex only for stable
   published GitHub releases. Manual dispatch validates without publishing.
   Document required npm_token and HEX_API_KEY secrets and recovery steps.
5. Run the full suite, review the complete diff, push the authorized main update,
   and confirm GitHub CI and the manual release validation workflow pass.

## Constraints

Keep the 90% Mix coverage minimum, all upstream goldens and executable oracles.
Use built-in packaging/testing commands. Credentials never enter source files.
Publication is public even while the source repository is private; explain this
in release instructions. No registry publication is authorized by this task.

## Interfaces and review focus

CI is reusable by release; release must test exactly the checkout it publishes.
Both tarballs must be validated through isolated consumer installations.
Check mismatched tags, missing credentials, draft/prerelease events, test failure,
partial publication and retry behavior. Check generated files remain untouched.

## Verification

npm ci --ignore-scripts; npm run test:all on Node 20 and Elixir 1.20.4.
Fresh remote matrix and manual dry-run release workflow after push.

Decision: Hex 2.5.1 authenticates before its dry-run guard; use secret-free
Hex build and consumer checks in ordinary CI, with authenticated dry-run only
in the release upload job. This preserves PR checks without publication secrets.

Review: no critical or important workflow issues. Include the release guide
in the npm archive because its packaged README links to it. Local full gate
and actionlint passed; remote matrix and manual validation remain to run.
