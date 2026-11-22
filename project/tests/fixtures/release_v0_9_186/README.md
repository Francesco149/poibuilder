# Release-compatibility fixture — v0.9.186 (GitHub release tag `v0.9.186` = `f67418c`)

`release_fixture.scn` was written BY THE RELEASE'S OWN CODE, and
`release_fixture.json` holds what that release read back from it (mask sizes,
pixel hashes, decal windows, splat bounds). `tests/test_pb_release_compat.gd`
loads the scene with the current code and requires the same answers, plus
that it renders, paints, saves and undoes.

This is the contract with maps users made on the public release. It is NOT a
regenerable build artifact: regenerating it with the current tree would make
the test compare the code with itself. To refresh it (or add one for a newer
release), run `tools/release_fixture/make_release_fixture.sh <commit> <dir>`,
which builds it inside a worktree of that release commit.

Unlike v0.9.167, this release already saved masks in the compressed
`PBMaskTexture` form (v0.9.182+), so the test expects no conversion on save.
Built with `tools/release_fixture/make_release_fixture.sh f67418c release_v0_9_186`.
