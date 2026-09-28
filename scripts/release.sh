#!/bin/sh
# Cuts a release: bumps the version everywhere, checks the build, moves main to the release commit
# and tags it. It never pushes; it prints the push command at the end.
#
#   scripts/release.sh 0.2.0
#
# Plugin and `npx skills` installs both read the default branch (main), so main must only ever
# point at a released commit. Development happens on dev (see AGENTS.md, "Releasing").
set -eu

die() { printf 'release: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: scripts/release.sh <version>   (e.g. 0.2.0)"
version=$1
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must look like 1.2.3"

cd "$(dirname "$0")/.."
[ "$(git rev-parse --abbrev-ref HEAD)" = dev ] || die "run it on the dev branch"
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && die "tag v$version already exists"
git merge-base --is-ancestor main dev || die "main has commits that dev doesn't; main must only move forward to dev"

files="Sources/iphone-use/IPhoneUse.swift .claude-plugin/plugin.json .claude-plugin/marketplace.json skills/iphone-use/scripts/iphone-use"
# If anything below fails before the commit, put the version files back so dev stays clean.
committed=0
trap '[ "$committed" = 1 ] || git checkout -q -- $files' EXIT

# The version lives in four places. The wrapper keys its build cache by version, so a missed one
# means users keep running an old binary.
sed -i '' -E "s/(version: \")[0-9.]+(\")/\1$version\2/" Sources/iphone-use/IPhoneUse.swift
sed -i '' -E "s/(\"version\": \")[0-9.]+(\")/\1$version\2/" .claude-plugin/plugin.json .claude-plugin/marketplace.json
sed -i '' -E "s/^VERSION=[0-9.]+$/VERSION=$version/" skills/iphone-use/scripts/iphone-use

for file in $files; do
    grep -q "$version" "$file" || die "could not set the version in $file"
done

echo "release: building (release configuration)..."
swift build -c release >/dev/null || die "release build failed"
built=$(.build/release/iphone-use --version)
[ "$built" = "$version" ] || die "the built binary reports $built, not $version"

if command -v claude >/dev/null 2>&1; then
    claude plugin validate . >/dev/null || die "claude plugin validate failed"
else
    echo "release: claude CLI not found; skipping plugin validation"
fi

if [ -n "$(git status --porcelain)" ]; then
    git commit -q -am "Release v$version"
fi
committed=1
git switch -q main
git merge -q --ff-only dev
git tag -a "v$version" -m "v$version"
git switch -q dev

echo "release: main and tag v$version point at $(git rev-parse --short "v$version^{commit}")."
echo "release: publish with:  git push --atomic origin dev main v$version"
