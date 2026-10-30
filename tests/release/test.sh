#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
STATE="$TMP/gh-state"
ARTIFACTS="$TMP/artifacts"
mkdir -p "$BIN" "$STATE" "$ARTIFACTS"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >> "${GH_LOG:?}"
printf '\n' >> "${GH_LOG:?}"
[ "${1:-}" = release ] || exit 2
action=$2
tag=${3:-}
key=${tag//\//__}
case $action in
    view)
        [ -f "$GH_STATE/$key.assets" ] || exit 1
        for arg in "$@"; do
            case $arg in
                '.assets[].name') cat "$GH_STATE/$key.assets"; exit 0 ;;
                .isPrerelease) cat "$GH_STATE/$key.pre"; exit 0 ;;
            esac
        done
        ;;
    download)
        destination=''
        while [ "$#" -gt 0 ]; do
            case $1 in
                --dir) destination=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        cp "$GH_STATE/$key.files"/* "$destination/"
        ;;
    create)
        mkdir -p "$GH_STATE/$key.files"
        assets=()
        for arg in "$@"; do
            case $arg in
                *.deb|*/SHA256SUMS)
                    cp "$arg" "$GH_STATE/$key.files/"
                    assets+=("$(basename "$arg")")
                    ;;
            esac
        done
        printf '%s\n' "${assets[@]}" | sort > "$GH_STATE/$key.assets"
        printf 'true\n' > "$GH_STATE/$key.pre"
        ;;
    edit)
        printf 'false\n' > "$GH_STATE/$key.pre"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "$BIN/gh"
export PATH="$BIN:$PATH" GH_LOG="$TMP/gh.log" GH_STATE="$STATE" GH_REPO='example/repo'
: > "$GH_LOG"

make_deb() {
    local directory=$1 package=$2 version=$3 architecture=$4 output=$5
    local build="$TMP/build-${RANDOM}"
    mkdir -p "$build/DEBIAN"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: test <test@example.invalid>\nDescription: test\n test\n' \
        "$package" "$version" "$architecture" > "$build/DEBIAN/control"
    mkdir -p "$directory"
    dpkg-deb --root-owner-group --build "$build" "$directory/$output" >/dev/null
    rm -rf "$build"
    (cd "$directory" && sha256sum -- "$output" > SHA256SUMS)
}

source "$ROOT/scripts/lib-release.sh"

section_notes=$(release_changelog_notes 'file-restore/4.2.8-1+ntfs3g3' test-commit)
grep -qF 'Version bump' <<<"$section_notes"
generated_notes=$(release_changelog_notes 'meta/9.9.9' test-commit)
previous_meta=$(git -C "$ROOT" show HEAD^:upstream.lock 2>/dev/null |
    awk '$1 == "meta" { print $2; exit }' || true)
if [ -n "$previous_meta" ]; then
    grep -qF "upstream bump $previous_meta -> 9.9.9" <<<"$generated_notes"
else
    grep -qF 'new release 9.9.9' <<<"$generated_notes"
fi
if grep -qF unknown <<<"$generated_notes"; then
    echo 'generated note contains unknown' >&2
    exit 1
fi

meta_version=$(lock_field meta version)
meta_deb=$(release_expected_asset meta "$meta_version")
bad="$TMP/bad"
make_deb "$bad/version" pve-file-restore-ntfs3g 9.9.9 all "$meta_deb"
if release_validate_directory meta "$meta_version" "$bad/version" >"$TMP/version.out" 2>&1; then
    echo 'version mismatch unexpectedly passed' >&2
    exit 1
fi
make_deb "$bad/package" wrong-package "$meta_version" all "$meta_deb"
if release_validate_directory meta "$meta_version" "$bad/package" >"$TMP/package.out" 2>&1; then
    echo 'wrong Package unexpectedly passed' >&2
    exit 1
fi
make_deb "$bad/architecture" pve-file-restore-ntfs3g "$meta_version" amd64 "$meta_deb"
if release_validate_directory meta "$meta_version" "$bad/architecture" >"$TMP/architecture.out" 2>&1; then
    echo 'wrong Architecture unexpectedly passed' >&2
    exit 1
fi
if release_validate_asset_names "$meta_deb" "${meta_deb%.deb}~.deb" SHA256SUMS >"$TMP/tilde.out" 2>&1; then
    echo 'GitHub-rewritten asset unexpectedly passed' >&2
    exit 1
fi
mkdir -p "$bad/extra"
make_deb "$bad/extra" pve-file-restore-ntfs3g "$meta_version" all "$meta_deb"
touch "$bad/extra/stale.deb"
if release_validate_directory meta "$meta_version" "$bad/extra" >"$TMP/extra.out" 2>&1; then
    echo 'extra stale deb unexpectedly passed' >&2
    exit 1
fi

for component in file-restore restore-image dedup-plugin meta; do
    version=$(lock_field "$component" version)
    package=$(lock_package "$component")
    architecture=$(lock_architecture "$component")
    output=$(release_expected_asset "$component" "$version")
    make_deb "$ARTIFACTS/$component" "$package" "$version" "$architecture" "$output"
done
scripts_release="$ROOT/scripts/release.sh"
"$scripts_release" "$ARTIFACTS" > "$TMP/release.out"
grep -qF 'published meta/' "$TMP/release.out"
grep -qF -- '--latest=false' "$GH_LOG"

"$ROOT/scripts/promote.sh" "meta/$meta_version" > "$TMP/promote.out"
grep -qF 'release download' "$GH_LOG"
grep -qF -- '--repo example/repo' "$GH_LOG"
grep -qF -- '--latest=false' "$GH_LOG"

mkdir -p "$TMP/no-artifacts"
"$scripts_release" "$TMP/no-artifacts" > "$TMP/existing-no-artifact.out"
grep -qF 'already exists' "$TMP/existing-no-artifact.out"

meta_key="meta__${meta_version}"
rm -f "$STATE/$meta_key.assets"
if "$scripts_release" "$TMP/no-artifacts" meta > "$TMP/missing-no-artifact.out" 2>&1; then
    echo 'missing tag without artifact unexpectedly passed' >&2
    exit 1
fi
grep -qF 'missing build artifact directory' "$TMP/missing-no-artifact.out"

# The promote path uses the same package-field validation: a downloadable
# release with an incorrect Version must not reach gh release edit.
bad_tag='meta/2.1.2'
bad_key=${bad_tag//\//__}
mkdir -p "$STATE/$bad_key.files"
bad_asset='pve-file-restore-ntfs3g_2.1.2_all.deb'
make_deb "$TMP/bad-remote" pve-file-restore-ntfs3g "$meta_version" all "$bad_asset"
cp "$TMP/bad-remote/$bad_asset" "$STATE/$bad_key.files/"
cp "$TMP/bad-remote/SHA256SUMS" "$STATE/$bad_key.files/"
printf '%s\nSHA256SUMS\n' "$bad_asset" > "$STATE/$bad_key.assets"
printf 'true\n' > "$STATE/$bad_key.pre"
if "$ROOT/scripts/promote.sh" "$bad_tag" > "$TMP/bad-promote.out" 2>&1; then
    echo 'promotion accepted a Version mismatch' >&2
    exit 1
fi

echo 'release tests passed'
