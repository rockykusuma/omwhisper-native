# Release notes

Hand-written notes for a release go in `vX.Y.Z.md` (e.g. `v2.1.0.md`).
`scripts/publish-release.sh` picks the file up automatically when creating the
GitHub release.

If no file exists for the version being published, `gh --generate-notes` is
used instead — so a patch release never blocks on writing prose, and a release
that deserves real notes can have them.
