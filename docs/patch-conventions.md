# Patch conventions

Rules for this series and for the ports that follow it. They exist because the
first publication shipped four patches that could not be applied at all, and
one that had hunk headers written by hand with invented line numbers. Nobody
noticed until the series was replayed against a pristine checkout, and until
then the repository looked complete while being unusable.

## Generate patches with git, never by hand

Use `git diff` or `git format-patch`. Both emit canonical, parsable output.

```sh
git diff path/to/file > /tmp/body.patch
```

Never assemble a hunk header. `@@ -0,0 +1,42 @@` written by hand is wrong more
often than it is right, and `wc -l` pads its output with spaces, which turns
the count into something `patch(1)` refuses to parse.

For a file the patch creates, let a tool produce the header:

```sh
diff -u /dev/null path/to/new_file
```

## Keep the rationale, generate the body

Each patch is a written explanation followed by a generated diff:

```sh
{ cat rationale.txt; git diff path/to/file; } > NNN-short-name.patch
```

The explanation names the root cause rather than the symptom, because several
of these look like one thing and are another. Regenerating the body after an
edit is then a one-line operation that cannot corrupt the header.

## The series is sequential

Several patches touch regions an earlier one created, so no patch after the
first can be validated against an unpatched tree. `patch --dry-run` on the
whole series against pristine upstream reports false failures for 004, 018 and
023. Validate by replaying the whole series in order instead.

## Verify by replay, not by inspection

Before publishing, apply every patch to a pristine checkout of the upstream
commit the series targets, and compare the result against the tree that was
actually tested:

```sh
git clone <upstream> /tmp/replay && cd /tmp/replay
git checkout <base-commit> && git clean -qfdx
for p in patches/*.patch; do patch -p1 --forward -s < "$p" || echo "FAILED $p"; done
find . -name '*.orig' -o -name '*.rej'          # must be empty
diff -rq --exclude=.git /tmp/replay <working-tree>   # must be empty
```

Both must come back empty. A patch that applies is not the same as a patch that
reproduces what was tested: patch 018 applied cleanly while carrying an older
version of a comment than the tree it was supposed to describe.

## The installer rolls back

`scripts/install.sh` applies the series in order and, on the first failure,
restores the tree with `git checkout -- .` and `git clean -fd` before exiting.
A half-patched tree must never reach the build, because the resulting failures
have nothing to do with the patch that actually broke.
