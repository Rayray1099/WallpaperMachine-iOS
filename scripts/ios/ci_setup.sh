#!/usr/bin/env bash
# Prepare a GitHub macOS runner for the iOS device build (cross-compiled arm64).
#
# Installs the tools the renderer and XcodeGen need (CMake, Ninja, pkg-config,
# XcodeGen, ccache) and adds the iOS Rust targets for both the pinned nightly
# toolchain in Renderer/rust-toolchain.toml and stable. The Xcode selection and
# SDK detection happen in scripts/ios/build.py, which reads the installed SDK
# instead of assuming an iOS 27 SDK.
#
# This does not install iOS libraries from Homebrew: Homebrew bottles are built
# for macOS and cannot be linked into an iOS arm64 app. The renderer script owns
# building or vendoring its iOS dependencies.
set -euo pipefail

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

step "Host"
uname -a
machine="$(uname -m)"
printf '  host architecture: %s (device output is cross-compiled as arm64)\n' "$machine"
sw_vers

step "Xcode installations"
if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1; then
  fail "no Xcode command-line tools; the runner image must provide Xcode"
fi
# Pick the newest stable Xcode and export its Developer directory. build.py
# applies the same rule; exporting it here keeps every later xcrun consistent
# and avoids assuming that xcode-select already points at Xcode.
xcode_app=""
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  case "$app" in
    *[Bb]eta*|*[Rr][Cc]*) continue ;;
  esac
  xcode_app="$app"
done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V)
if [[ -z "$xcode_app" ]]; then
  fail "no stable Xcode found in /Applications"
fi
export DEVELOPER_DIR="${xcode_app}/Contents/Developer"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "DEVELOPER_DIR=${DEVELOPER_DIR}" >> "$GITHUB_ENV"
fi
printf '  selected %s\n' "$DEVELOPER_DIR"
xcode-select -p || true
for app in /Applications/Xcode*.app; do
  [[ -d "$app" ]] || continue
  printf '  %s\n' "$app"
done
xcodebuild -version

step "Homebrew tools"
if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew is not installed on the runner"
fi
for formula in xcodegen cmake ninja pkg-config ccache; do
  if brew list --versions "$formula" >/dev/null 2>&1; then
    printf '  %s already installed\n' "$formula"
  else
    brew install --quiet "$formula"
  fi
done
xcodegen --version
cmake --version | head -n 1
ninja --version
pkg-config --version
ccache --version | head -n 1

step "Rust toolchains and iOS targets"
if ! command -v rustup >/dev/null 2>&1; then
  fail "rustup is not installed on the runner"
fi
rustup toolchain install stable --profile minimal --no-self-update
# The workspace pins a channel in Renderer/rust-toolchain.toml. Add the iOS
# targets to that toolchain explicitly: the file is not an ancestor of the
# repository root, so a `rustup target add` at the root would touch a different
# toolchain than a cargo invocation from Renderer/.
pinned_channel="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' Renderer/rust-toolchain.toml | head -n 1)"
[[ -n "$pinned_channel" ]] || fail "Renderer/rust-toolchain.toml does not name a channel"
rustup toolchain install "$pinned_channel" --profile minimal --no-self-update
rustup target add --toolchain stable aarch64-apple-ios aarch64-apple-ios-sim
rustup target add --toolchain "$pinned_channel" aarch64-apple-ios aarch64-apple-ios-sim
printf '  pinned toolchain: %s\n' "$pinned_channel"
(cd Renderer && rustup show active-toolchain)
rustc --version
cargo --version
for toolchain in stable "$pinned_channel"; do
  installed="$(rustup target list --installed --toolchain "$toolchain" 2>/dev/null || true)"
  if ! grep -qx 'aarch64-apple-ios' <<<"$installed"; then
    fail "aarch64-apple-ios is not installed for the ${toolchain} toolchain"
  fi
  printf '  %s: %s\n' "$toolchain" "$(tr '\n' ' ' <<<"$installed")"
done

step "Caches"
# The workflow caches ~/.ccache and Renderer/target. These settings must match
# the cache path and keep object hashes independent of the checkout directory.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "CCACHE_DIR=${HOME}/.ccache"
    echo "CCACHE_BASEDIR=${GITHUB_WORKSPACE:-$PWD}"
    echo "CCACHE_COMPILERCHECK=%compiler% -v"
    echo "CCACHE_MAXSIZE=2G"
  } >> "$GITHUB_ENV"
fi

step "iPhoneOS SDK"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
[[ -d "$sdk_path" ]] || fail "the iPhoneOS SDK path does not exist: ${sdk_path}"
printf '  iPhoneOS SDK %s at %s\n' "$sdk_version" "$sdk_path"
# Do not assume iOS 27: only the deployment floor is checked here, and build.py
# re-checks the selected SDK after choosing the newest stable Xcode.
sdk_major="${sdk_version%%.*}"
if [[ "$sdk_major" -lt 18 ]]; then
  fail "iPhoneOS SDK ${sdk_version} is older than the iOS 18 deployment floor"
fi

step "Ready"
printf 'Runner prepared for the unsigned arm64 iOS build.\n'
