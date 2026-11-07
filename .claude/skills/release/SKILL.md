---
name: release
description: Prepare and publish a Varmepumpe release — choose the version, write the CHANGELOG entry (it becomes the GitHub release notes and the in-app "What's new"), bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml for both targets, verify, tag vX.Y.Z and let the GitHub release workflow sign, notarize and publish. Use when the user asks for a release, a new version, or to ship merged work.
---

# Release

Releases are built, Developer ID signed, notarized and published by
`.github/workflows/release.yml` when a tag `vX.Y.Z` is pushed. Installed apps find new versions
through GitHub's "latest release" and update themselves, so a broken release reaches users
within a day. Pushing and tagging are outward actions: **ask the user before `git push` and
before pushing a tag**, every time.

## Steps

1. **Start clean.** On `main`, up to date with `origin/main`, working tree clean, the work merged
   (via PR when it came from a branch).
2. **Choose the version** (semver): patch for fixes, minor for features, major for breaking
   changes such as a one-way database migration. Look at the last entry in `CHANGELOG.md` and
   `git log <last tag>..HEAD`.
3. **CHANGELOG.md**: add `## [X.Y.Z] – YYYY-MM-DD` (en dash) above the previous entry. English,
   one bullet per user-visible change, bold lead-in, written for users rather than developers:
   ```
   - **Weekly schedule**: copy a day to other days with one click. …
   ```
   The release workflow copies exactly this section into the GitHub release notes, and the app
   shows it as "What's new", so no internal details, file names or PR numbers.
4. **project.yml**: set `MARKETING_VERSION: "X.Y.Z"` and increment `CURRENT_PROJECT_VERSION` by
   one, in **both** targets (`Varmepumpe` and `varmepumpe-mcp`; they must match).
5. **README**: update when features, tools or screenshots changed (both `README.md` and `README.nb.md`).
6. **Verify**:
   ```sh
   make check
   python3 scripts/l10n.py check
   ```
   Optionally `SKIP_NOTARIZE=1 make release VERSION=X.Y.Z` locally to check Developer ID signing
   (needs the certificate in the keychain; the result does not pass Gatekeeper).
7. **Commit** `Release X.Y.Z` (CHANGELOG, project.yml, README).
8. **Ask the user**, then push and tag:
   ```sh
   git push origin main
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
9. **Follow the workflow**: `gh run list --workflow release.yml --limit 1`, then
   `gh run watch <id>`. When it finishes, check `gh release view vX.Y.Z`: the assets must be
   `Husly-X.Y.Z.dmg` (the download, holding `Husly.app`) and `Varmepumpe-X.Y.Z.zip` (the in-app updater reads only
   `.zip` assets; never drop it), each with a `.sha256`, and the release must not be a pre-release or
   draft (the updater ignores those).
10. Report the release URL and the download link
    `https://github.com/stigoleg/Heat-Pump/releases/latest/download/Husly-X.Y.Z.dmg`.

## If it fails

- Tests or build fail in the workflow: fix on `main`, delete the tag locally and remotely
  (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`, ask first), then tag again.
- Notarization fails: read the `notarytool log` output in the run; usually a missing hardened
  runtime flag or a `get-task-allow` entitlement (`scripts/release.sh` checks for it).
- Never publish a release by hand that skipped notarization.

Secrets the workflow needs are listed in the README under "Making a release".
