#!/usr/bin/env bash
# Build the real WallpaperMachine scene renderer for iOS (arm64).
#
# The iOS app links one static archive, built here from the same sources the macOS
# app uses:
#
#   * wm-shader        Renderer/Shader, Rust -> aarch64-apple-ios staticlib (ffi)
#   * the C++ engine   Renderer/Engine + Renderer/Media + Renderer/Sound +
#                      Renderer/Surface, with the C ABI in
#                      Renderer/Engine/src/Platform/Apple/SceneWallpaperBindings.h
#   * its iOS libraries QuickJS-ng, FreeType, LZ4, nlohmann/json and argparse,
#                      cross-compiled for the SDK rather than borrowed from
#                      Homebrew. Header-only dependencies are staged as headers.
#
# It never links a macOS or Homebrew binary and never changes ThirdParty/. The
# pinned archives are downloaded into Renderer/Engine/.ios-deps and verified
# against the SHA-256 constants below; the build trees live in
# Renderer/Engine/build-ios (both ignored by Git).
#
# Output (default iOS/Generated/Renderer, also ignored):
#   include/Platform/Apple/SceneWallpaperBindings.h
#   include/Core/RendererCounters.h
#   include/WallpaperSceneRenderer.h
#   lib/libWallpaperSceneRenderer.a    engine + QuickJS + FreeType + LZ4 + Rust
#   Renderer.xcconfig                  Xcode integration for the archive
#   link-flags.txt                     the same contract for humans
#   manifest.json                      versions, hashes, SDK and compiler
#
# Requirements on the build machine: macOS with Xcode (xcrun), CMake >= 3.20,
# pkg-config, a C toolchain from Xcode, and Rust with the iOS target (rustup is
# used to add it when present). Network access is needed only on the first run
# or after --clean.
#
# Usage:
#   scripts/ios/build_renderer.sh                 # device arm64
#   scripts/ios/build_renderer.sh --simulator     # Apple-silicon simulator
#   scripts/ios/build_renderer.sh --dry-run       # print the plan, touch nothing
#   scripts/ios/build_renderer.sh --clean         # remove this script's caches
#
# This script is also valid Bash 3.2, the system Bash on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"

if [ ! -d "${REPO_ROOT}/Renderer/Engine" ] || [ ! -d "${REPO_ROOT}/Renderer/Shader" ]; then
  printf 'error: %s is not a WallpaperMachine checkout\n' "${REPO_ROOT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Pinned third-party dependencies. Every URL is a source archive, never a
# prebuilt binary, so the result is compiled for the iOS SDK by this machine.
# The SHA-256 values were computed from the exact archives.
# ---------------------------------------------------------------------------
QUICKJS_VERSION="0.17.0"
QUICKJS_TAG="v${QUICKJS_VERSION}"
QUICKJS_SHA256="559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"
QUICKJS_URL="https://github.com/quickjs-ng/quickjs/archive/refs/tags/${QUICKJS_TAG}.tar.gz"
QUICKJS_DIR="quickjs-${QUICKJS_VERSION}"

FREETYPE_VERSION="2.13.3"
FREETYPE_TAG="VER-2-13-3"
FREETYPE_SHA256="bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103"
FREETYPE_URL="https://github.com/freetype/freetype/archive/refs/tags/${FREETYPE_TAG}.tar.gz"
FREETYPE_DIR="freetype-${FREETYPE_TAG}"

LZ4_VERSION="1.10.0"
LZ4_TAG="v${LZ4_VERSION}"
LZ4_SHA256="537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b"
LZ4_URL="https://github.com/lz4/lz4/archive/refs/tags/${LZ4_TAG}.tar.gz"
LZ4_DIR="lz4-${LZ4_VERSION}"

NLOHMANN_VERSION="3.12.0"
NLOHMANN_SHA256="aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63"
NLOHMANN_URL="https://github.com/nlohmann/json/releases/download/v${NLOHMANN_VERSION}/json.hpp"

ARGPARSE_VERSION="3.2"
ARGPARSE_TAG="v${ARGPARSE_VERSION}"
ARGPARSE_SHA256="9dcb3d8ce0a41b2a48ac8baa54b51a9f1b6a2c52dd374e28cc713bab0568ec98"
ARGPARSE_URL="https://github.com/p-ranav/argparse/archive/refs/tags/${ARGPARSE_TAG}.tar.gz"
ARGPARSE_DIR="argparse-${ARGPARSE_VERSION}"

DEFAULT_DEPLOYMENT_TARGET="18.0"

SDK="iphoneos"
ARCH="arm64"
DEPLOYMENT_TARGET="${DEFAULT_DEPLOYMENT_TARGET}"
CONFIGURATION="Release"
VERBOSE=false
DRY_RUN=false
CLEAN=false
BUILD_DEPS=true
DEPS_ONLY=false
OUT_DIR=""

DEPS_CACHE="${WM_IOS_DEPS_CACHE:-${REPO_ROOT}/Renderer/Engine/.ios-deps}"
BUILD_CACHE="${WM_IOS_BUILD_CACHE:-${REPO_ROOT}/Renderer/Engine/build-ios}"

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)
      [ $# -ge 2 ] || fail "--sdk needs a value"
      SDK="$2"
      shift 2
      ;;
    --simulator)
      SDK="iphonesimulator"
      shift
      ;;
    --device)
      SDK="iphoneos"
      shift
      ;;
    --arch)
      [ $# -ge 2 ] || fail "--arch needs a value"
      ARCH="$2"
      shift 2
      ;;
    --deployment-target)
      [ $# -ge 2 ] || fail "--deployment-target needs a value"
      DEPLOYMENT_TARGET="$2"
      shift 2
      ;;
    --configuration)
      [ $# -ge 2 ] || fail "--configuration needs a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    --out)
      [ $# -ge 2 ] || fail "--out needs a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --deps-cache)
      [ $# -ge 2 ] || fail "--deps-cache needs a value"
      DEPS_CACHE="$2"
      shift 2
      ;;
    --skip-deps)
      BUILD_DEPS=false
      shift
      ;;
    --deps-only)
      DEPS_ONLY=true
      shift
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      fail "unknown argument: $1 (try --help)"
      ;;
  esac
done

case "${SDK}" in
  iphoneos|iphonesimulator) ;;
  *) fail "--sdk must be iphoneos or iphonesimulator" ;;
esac
case "${ARCH}" in
  arm64|x86_64) ;;
  *) fail "--arch must be arm64 or x86_64" ;;
esac
case "${CONFIGURATION}" in
  Release|Debug) ;;
  *) fail "--configuration must be Release or Debug" ;;
esac
if [ "${SDK}" = "iphoneos" ] && [ "${ARCH}" != "arm64" ]; then
  fail "the device SDK is arm64; use --simulator for x86_64"
fi

case "${DEPLOYMENT_TARGET}" in
  [0-9]*.[0-9]*) ;;
  *) fail "--deployment-target must look like 18.0" ;;
esac
if awk -v target="${DEPLOYMENT_TARGET}" 'BEGIN { exit !(target >= 18.0) }' </dev/null; then
  :
else
  printf 'warning: deployment target %s is below the iOS 18 application floor\n' "${DEPLOYMENT_TARGET}" >&2
fi

if [ -z "${OUT_DIR}" ]; then
  if [ "${SDK}" = "iphoneos" ]; then
    OUT_DIR="${REPO_ROOT}/iOS/Generated/Renderer"
  else
    OUT_DIR="${REPO_ROOT}/iOS/Generated/Renderer-simulator"
  fi
elif [ "${OUT_DIR#/}" = "${OUT_DIR}" ]; then
  OUT_DIR="${REPO_ROOT}/${OUT_DIR}"
fi

if [ "${SDK}" = "iphoneos" ]; then
  RUST_TARGET="aarch64-apple-ios"
else
  if [ "${ARCH}" = "arm64" ]; then
    RUST_TARGET="aarch64-apple-ios-sim"
  else
    RUST_TARGET="x86_64-apple-ios"
  fi
fi

# One cache and one build tree per SDK/arch: the libraries contain platform
# objects and must never be reused across SDKs.
PLATFORM_STEM="${SDK}-${ARCH}"
DEPS_PREFIX="${DEPS_CACHE}/${PLATFORM_STEM}/prefix"
DEPS_SOURCES="${DEPS_CACHE}/src"
DEPS_DOWNLOADS="${DEPS_CACHE}/downloads"
BUILD_ROOT="${BUILD_CACHE}/${PLATFORM_STEM}"
LOG_DIR="${BUILD_ROOT}/logs"
ENGINE_SOURCE="${REPO_ROOT}/Renderer/Engine"
RUST_LIB="${REPO_ROOT}/Renderer/target/${RUST_TARGET}/release/libwm_shader.a"
ENGINE_LIB="${BUILD_ROOT}/engine/src/libwescene-renderer.a"
FINAL_LIB="${OUT_DIR}/lib/libWallpaperSceneRenderer.a"

write_plan() {
  cat <<EOF
WallpaperMachine iOS renderer build plan
  repository:        ${REPO_ROOT}
  SDK:               ${SDK} (${ARCH})
  deployment target: ${DEPLOYMENT_TARGET}
  configuration:     ${CONFIGURATION}
  Rust target:       ${RUST_TARGET}
  engine source:     ${ENGINE_SOURCE}
  dependencies:      ${DEPS_PREFIX}
  build tree:        ${BUILD_ROOT}
  output:            ${OUT_DIR}
  final archive:     ${FINAL_LIB}
  cache:             ${DEPS_CACHE}
  pinned:
    QuickJS-ng ${QUICKJS_VERSION}  sha256 ${QUICKJS_SHA256}
    FreeType   ${FREETYPE_VERSION}  sha256 ${FREETYPE_SHA256}
    LZ4        ${LZ4_VERSION}  sha256 ${LZ4_SHA256}
    nlohmann/json ${NLOHMANN_VERSION}  sha256 ${NLOHMANN_SHA256}
    argparse   ${ARGPARSE_VERSION}  sha256 ${ARGPARSE_SHA256}
EOF
}

if [ "${CLEAN}" = "true" ]; then
  case "${BUILD_ROOT}" in
    "${REPO_ROOT}"/Renderer/Engine/build-ios/*) ;;
    *) fail "refusing to clean outside Renderer/Engine/build-ios: ${BUILD_ROOT}" ;;
  esac
  case "${DEPS_CACHE}" in
    "${REPO_ROOT}"/Renderer/Engine/.ios-deps|"${REPO_ROOT}"/Renderer/Engine/.ios-deps/*) ;;
    *) fail "refusing to clean outside Renderer/Engine/.ios-deps: ${DEPS_CACHE}" ;;
  esac
  rm -rf "${BUILD_ROOT}"
  rm -rf "${DEPS_CACHE}"
  log "removed ${BUILD_ROOT} and ${DEPS_CACHE}"
  exit 0
fi

if [ "${DRY_RUN}" = "true" ]; then
  write_plan
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || fail "the iOS renderer can only be built on macOS (Xcode SDK required)"

command -v xcrun >/dev/null 2>&1 || fail "xcrun not found; install Xcode and select it with xcode-select"
command -v cmake >/dev/null 2>&1 || fail "cmake not found; install CMake (3.20 or later)"
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config not found; install it (for example: brew install pkg-config)"
cmake_version="$(cmake --version | awk 'NR == 1 { print $3 }')"
if ! awk -v version="${cmake_version}" 'BEGIN {
      split(version, v, ".");
      exit !((v[1] + 0) > 3 || ((v[1] + 0) == 3 && (v[2] + 0) >= 20));
    }' </dev/null; then
  fail "cmake ${cmake_version} is too old; 3.20 or later is required"
fi

command -v cargo >/dev/null 2>&1 || fail "cargo not found; install the Rust toolchain (rustup)"
if command -v rustup >/dev/null 2>&1; then
  # Run inside Renderer/: rust-toolchain.toml pins the toolchain cargo will use,
  # and the target must be installed for that same toolchain.
  if ! ( cd "${REPO_ROOT}/Renderer" && rustup target list --installed 2>/dev/null | grep -qx "${RUST_TARGET}" ); then
    log "adding Rust target ${RUST_TARGET}"
    ( cd "${REPO_ROOT}/Renderer" && rustup target add "${RUST_TARGET}" )
  fi
else
  [ -f "${RUST_LIB}" ] || fail "rustup not found and ${RUST_LIB} is absent; install rustup and run rustup target add ${RUST_TARGET}"
fi

SDK_PATH="$(xcrun --sdk "${SDK}" --show-sdk-path)"
[ -d "${SDK_PATH}" ] || fail "the ${SDK} SDK path does not exist: ${SDK_PATH}"
SDK_VERSION="$(xcrun --sdk "${SDK}" --show-sdk-version)"
CC="$(xcrun --sdk "${SDK}" --find clang)"
CXX="$(xcrun --sdk "${SDK}" --find clang++)"
[ -x "${CC}" ] || fail "clang not found in the ${SDK} SDK"
[ -x "${CXX}" ] || fail "clang++ not found in the ${SDK} SDK"

if command -v ninja >/dev/null 2>&1; then
  GENERATOR=(-G Ninja)
else
  GENERATOR=(-G "Unix Makefiles")
fi
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

mkdir -p "${DEPS_DOWNLOADS}" "${DEPS_SOURCES}" "${DEPS_PREFIX}" "${BUILD_ROOT}" "${LOG_DIR}" "${OUT_DIR}/include" "${OUT_DIR}/lib"

if [ "${BUILD_DEPS}" = "true" ]; then
  :
elif [ ! -f "${DEPS_PREFIX}/lib/libqjs.a" ] || [ ! -f "${DEPS_PREFIX}/lib/libfreetype.a" ] || [ ! -f "${DEPS_PREFIX}/lib/liblz4.a" ]; then
  fail "--skip-deps was given but ${DEPS_PREFIX} has no complete iOS dependency set"
fi

CMAKE_COMMON=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_ARCHITECTURES="${ARCH}"
  -DCMAKE_OSX_SYSROOT="${SDK_PATH}"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}"
  -DCMAKE_C_COMPILER="${CC}"
  -DCMAKE_CXX_COMPILER="${CXX}"
  -DCMAKE_OBJC_COMPILER="${CC}"
  -DCMAKE_OBJCXX_COMPILER="${CXX}"
  -DCMAKE_BUILD_TYPE="${CONFIGURATION}"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
)

run_logged() {
  stage="$1"
  shift
  log "${stage}"
  if [ "${VERBOSE}" = "true" ]; then
    "$@"
    return
  fi
  log_file="${LOG_DIR}/${stage}.log"
  if ! "$@" >"${log_file}" 2>&1; then
    printf 'error: %s failed; last 100 lines of %s\n' "${stage}" "${log_file}" >&2
    tail -n 100 "${log_file}" >&2 || true
    exit 1
  fi
}

download() {
  url="$1"
  name="$2"
  expected="$3"
  destination="${DEPS_DOWNLOADS}/${name}"
  if [ -f "${destination}" ]; then
    actual="$(shasum -a 256 "${destination}" | awk '{ print $1 }')"
    [ "${actual}" = "${expected}" ] || fail "cached ${name} has the wrong SHA-256 (${actual})"
    return
  fi
  partial="${destination}.part"
  rm -f "${partial}"
  curl -fL --retry 3 --connect-timeout 20 --silent --show-error -o "${partial}" "${url}" \
    || fail "could not download ${url}"
  actual="$(shasum -a 256 "${partial}" | awk '{ print $1 }')"
  if [ "${actual}" != "${expected}" ]; then
    rm -f "${partial}"
    fail "${name} SHA-256 is ${actual}, expected ${expected}"
  fi
  mv "${partial}" "${destination}"
}

extract_if_needed() {
  archive="$1"
  directory_name="$2"
  if [ ! -d "${DEPS_SOURCES}/${directory_name}" ]; then
    tar -xzf "${archive}" -C "${DEPS_SOURCES}"
  fi
  [ -d "${DEPS_SOURCES}/${directory_name}" ] || fail "unpacking ${archive} did not produce ${directory_name}"
}

install_header_only_configs() {
  mkdir -p "${DEPS_PREFIX}/include/nlohmann"
  cp "${DEPS_DOWNLOADS}/json.hpp" "${DEPS_PREFIX}/include/nlohmann/json.hpp"
  mkdir -p "${DEPS_PREFIX}/include"
  cp -R "${DEPS_SOURCES}/${ARGPARSE_DIR}/include/." "${DEPS_PREFIX}/include/"

  mkdir -p "${DEPS_PREFIX}/lib/cmake/nlohmann_json"
  cat >"${DEPS_PREFIX}/lib/cmake/nlohmann_json/nlohmann_jsonConfig.cmake" <<EOF
# Generated by scripts/ios/build_renderer.sh (iOS sysroot), not Homebrew.
if(TARGET nlohmann_json::nlohmann_json)
  return()
endif()
add_library(nlohmann_json::nlohmann_json INTERFACE IMPORTED GLOBAL)
set_target_properties(nlohmann_json::nlohmann_json PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${DEPS_PREFIX}/include")
EOF

  mkdir -p "${DEPS_PREFIX}/lib/cmake/argparse"
  cat >"${DEPS_PREFIX}/lib/cmake/argparse/argparseConfig.cmake" <<EOF
# Generated by scripts/ios/build_renderer.sh (iOS sysroot), not Homebrew.
if(TARGET argparse::argparse)
  return()
endif()
add_library(argparse::argparse INTERFACE IMPORTED GLOBAL)
set_target_properties(argparse::argparse PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${DEPS_PREFIX}/include")
EOF

  mkdir -p "${DEPS_PREFIX}/lib/cmake/qjs"
  cat >"${DEPS_PREFIX}/lib/cmake/qjs/qjsConfig.cmake" <<EOF
# Generated by scripts/ios/build_renderer.sh (iOS sysroot), not Homebrew.
if(TARGET qjs)
  return()
endif()
add_library(qjs STATIC IMPORTED GLOBAL)
set_target_properties(qjs PROPERTIES
  IMPORTED_LOCATION "${DEPS_PREFIX}/lib/libqjs.a"
  INTERFACE_INCLUDE_DIRECTORIES "${DEPS_PREFIX}/include")
EOF
}

build_freetype() {
  if [ -f "${DEPS_PREFIX}/lib/libfreetype.a" ] && [ -f "${DEPS_PREFIX}/lib/pkgconfig/freetype2.pc" ] \
     && [ -f "${DEPS_PREFIX}/include/freetype2/ft2build.h" ]; then
    log "FreeType ${FREETYPE_VERSION}: cached"
    return
  fi
  source_dir="${DEPS_SOURCES}/${FREETYPE_DIR}"
  build_dir="${BUILD_ROOT}/deps/freetype"
  run_logged "cmake:freetype-configure" \
    cmake -S "${source_dir}" -B "${build_dir}" "${GENERATOR[@]}" "${CMAKE_COMMON[@]}" \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DFT_DISABLE_ZLIB=TRUE \
      -DFT_DISABLE_BZIP2=TRUE \
      -DFT_DISABLE_PNG=TRUE \
      -DFT_DISABLE_HARFBUZZ=TRUE \
      -DFT_DISABLE_BROTLI=TRUE
  run_logged "cmake:freetype-build" cmake --build "${build_dir}" --target install --parallel "${JOBS}"
}

build_lz4() {
  if [ -f "${DEPS_PREFIX}/lib/liblz4.a" ] && [ -f "${DEPS_PREFIX}/lib/pkgconfig/liblz4.pc" ] \
     && [ -f "${DEPS_PREFIX}/include/lz4.h" ]; then
    log "LZ4 ${LZ4_VERSION}: cached"
    return
  fi
  source_dir="${DEPS_SOURCES}/${LZ4_DIR}/build/cmake"
  build_dir="${BUILD_ROOT}/deps/lz4"
  run_logged "cmake:lz4-configure" \
    cmake -S "${source_dir}" -B "${build_dir}" "${GENERATOR[@]}" "${CMAKE_COMMON[@]}" \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_STATIC_LIBS=ON \
      -DLZ4_BUILD_CLI=OFF \
      -DLZ4_BUILD_LEGACY=OFF \
      -DLZ4_BUNDLED_MODE=OFF
  run_logged "cmake:lz4-build" cmake --build "${build_dir}" --target install --parallel "${JOBS}"
}

build_quickjs() {
  if [ -f "${DEPS_PREFIX}/lib/libqjs.a" ] && [ -f "${DEPS_PREFIX}/include/quickjs.h" ]; then
    log "QuickJS-ng ${QUICKJS_VERSION}: cached"
    return
  fi
  source_dir="${DEPS_SOURCES}/${QUICKJS_DIR}"
  build_dir="${BUILD_ROOT}/deps/quickjs"
  run_logged "cmake:quickjs-configure" \
    cmake -S "${source_dir}" -B "${build_dir}" "${GENERATOR[@]}" "${CMAKE_COMMON[@]}" \
      -DBUILD_SHARED_LIBS=OFF \
      -DQJS_BUILD_EXAMPLES=OFF \
      -DQJS_BUILD_CLI_STATIC=OFF \
      -DQJS_ENABLE_INSTALL=OFF
  run_logged "cmake:quickjs-build" cmake --build "${build_dir}" --target qjs --parallel "${JOBS}"
  quickjs_library="$(find "${build_dir}" -name 'libqjs.a' -type f -print -quit)"
  [ -n "${quickjs_library}" ] || fail "QuickJS build produced no libqjs.a"
  mkdir -p "${DEPS_PREFIX}/lib" "${DEPS_PREFIX}/include"
  cp "${quickjs_library}" "${DEPS_PREFIX}/lib/libqjs.a"
  cp "${source_dir}/quickjs.h" "${DEPS_PREFIX}/include/quickjs.h"
}

verify_archive_for_ios() {
  archive="$1"
  lipo_info="$(xcrun lipo -info "${archive}" 2>/dev/null || true)"
  case "${lipo_info}" in
    *"${ARCH}"*) ;;
    *) fail "${archive} is not ${ARCH}: ${lipo_info:-no architecture information}" ;;
  esac
  temporary="$(mktemp -d)"
  member="$(xcrun ar -t "${archive}" 2>/dev/null | head -n 1 || true)"
  if [ -n "${member}" ]; then
    ( cd "${temporary}" && xcrun ar -x "${archive}" "${member}" ) >/dev/null 2>&1 || true
    object="$(find "${temporary}" -type f -print -quit)"
    if [ -n "${object}" ]; then
      platform="$(xcrun vtool -show-build "${object}" 2>/dev/null | awk '/platform/ { print $2; exit }')"
      case "${platform}" in
        IOS|IOS_SIMULATOR) ;;
        *) fail "${archive} contains a non-iOS object (platform ${platform:-unknown})" ;;
      esac
    fi
  fi
  rm -rf "${temporary}"
}

if [ "${BUILD_DEPS}" = "true" ]; then
  download "${QUICKJS_URL}" "quickjs-${QUICKJS_VERSION}.tar.gz" "${QUICKJS_SHA256}"
  download "${FREETYPE_URL}" "freetype-${FREETYPE_VERSION}.tar.gz" "${FREETYPE_SHA256}"
  download "${LZ4_URL}" "lz4-${LZ4_VERSION}.tar.gz" "${LZ4_SHA256}"
  download "${NLOHMANN_URL}" "json.hpp" "${NLOHMANN_SHA256}"
  download "${ARGPARSE_URL}" "argparse-${ARGPARSE_VERSION}.tar.gz" "${ARGPARSE_SHA256}"

  extract_if_needed "${DEPS_DOWNLOADS}/quickjs-${QUICKJS_VERSION}.tar.gz" "${QUICKJS_DIR}"
  extract_if_needed "${DEPS_DOWNLOADS}/freetype-${FREETYPE_VERSION}.tar.gz" "${FREETYPE_DIR}"
  extract_if_needed "${DEPS_DOWNLOADS}/lz4-${LZ4_VERSION}.tar.gz" "${LZ4_DIR}"
  extract_if_needed "${DEPS_DOWNLOADS}/argparse-${ARGPARSE_VERSION}.tar.gz" "${ARGPARSE_DIR}"

  install_header_only_configs
  build_quickjs
  build_freetype
  build_lz4

  for archive in \
    "${DEPS_PREFIX}/lib/libqjs.a" \
    "${DEPS_PREFIX}/lib/libfreetype.a" \
    "${DEPS_PREFIX}/lib/liblz4.a"
  do
    [ -f "${archive}" ] || fail "missing dependency archive: ${archive}"
    verify_archive_for_ios "${archive}"
  done
else
  log "dependencies: using ${DEPS_PREFIX} (--skip-deps)"
fi

if [ "${DEPS_ONLY}" = "true" ]; then
  log "dependencies only; output in ${DEPS_PREFIX}"
  exit 0
fi

log "building wm-shader for ${RUST_TARGET}"
(
  cd "${REPO_ROOT}/Renderer"
  if [ "${VERBOSE}" = "true" ]; then
    IPHONEOS_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" cargo build --locked -p wm-shader --release --target "${RUST_TARGET}" --features ffi
  else
    IPHONEOS_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" cargo build --locked -p wm-shader --release --target "${RUST_TARGET}" --features ffi \
      >"${LOG_DIR}/cargo-wm-shader.log" 2>&1 || {
      printf 'error: cargo build -p wm-shader failed; last 100 lines of %s\n' "${LOG_DIR}/cargo-wm-shader.log" >&2
      tail -n 100 "${LOG_DIR}/cargo-wm-shader.log" >&2 || true
      exit 1
    }
  fi
)
[ -f "${RUST_LIB}" ] || fail "cargo did not produce ${RUST_LIB}"
verify_archive_for_ios "${RUST_LIB}"

# The engine's CMake looks dependencies up through these explicit config
# directories. Inherited Homebrew search paths are deliberately not used.
export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig"
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH CMAKE_INCLUDE_PATH CMAKE_LIBRARY_PATH 2>/dev/null || true

run_logged "cmake:engine-configure" \
  cmake -S "${ENGINE_SOURCE}" -B "${BUILD_ROOT}/engine" "${GENERATOR[@]}" "${CMAKE_COMMON[@]}" \
    -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
    -Dqjs_DIR="${DEPS_PREFIX}/lib/cmake/qjs" \
    -Dnlohmann_json_DIR="${DEPS_PREFIX}/lib/cmake/nlohmann_json" \
    -Dargparse_DIR="${DEPS_PREFIX}/lib/cmake/argparse" \
    -DBUILD_TESTS=OFF \
    -DBUILD_TESTING=OFF \
    -DRUST_SHADER_FFI=ON \
    -DRUST_SHADER_STATICLIB="${RUST_LIB}"

run_logged "cmake:engine-build" \
  cmake --build "${BUILD_ROOT}/engine" --target wescene-renderer --parallel "${JOBS}"

ARCHIVES=(
  "${ENGINE_LIB}"
  "${BUILD_ROOT}/engine/src/Audio/libwpAudio.a"
  "${BUILD_ROOT}/engine/src/Looper/libwpLooper.a"
  "${BUILD_ROOT}/engine/src/Scene/libwpScene.a"
  "${BUILD_ROOT}/engine/src/Scene/Particle/libwpParticle.a"
  "${BUILD_ROOT}/engine/src/Scene/RenderCommon/libwpRenderCommon.a"
  "${BUILD_ROOT}/engine/src/Scene/RenderGraph/libwpRGraph.a"
  "${BUILD_ROOT}/engine/src/Scene/Timer/libwpTimer.a"
  "${BUILD_ROOT}/engine/src/Scene/MetalRender/libwpMetalRender.a"
  "${BUILD_ROOT}/engine/src/Utils/libwpUtils.a"
  "${BUILD_ROOT}/engine/Dependencies/libstb_vorbis.a"
  "${BUILD_ROOT}/engine/Renderer/Media/libwmMedia.a"
  "${BUILD_ROOT}/engine/Renderer/Media/Apple/libwmMediaApple.a"
  "${BUILD_ROOT}/engine/Renderer/Sound/libwmSound.a"
  "${BUILD_ROOT}/engine/Renderer/Surface/libwmSurface.a"
  "${DEPS_PREFIX}/lib/libqjs.a"
  "${DEPS_PREFIX}/lib/libfreetype.a"
  "${DEPS_PREFIX}/lib/liblz4.a"
  "${RUST_LIB}"
)
for archive in "${ARCHIVES[@]}"; do
  [ -f "${archive}" ] || fail "the engine build did not produce ${archive}"
done

log "merging ${#ARCHIVES[@]} archives into ${FINAL_LIB}"
rm -f "${FINAL_LIB}"
xcrun libtool -static -o "${FINAL_LIB}" "${ARCHIVES[@]}"

verify_archive_for_ios "${FINAL_LIB}"
nm_output="$(xcrun nm -g "${FINAL_LIB}" 2>/dev/null || true)"
case "${nm_output}" in
  *"_owe_scene_wallpaper_new"*) ;;
  *) fail "the merged archive does not export owe_scene_wallpaper_new" ;;
esac
case "${nm_output}" in
  *"_rs_shader_compile_program"*) ;;
  *) fail "the merged archive does not export rs_shader_compile_program (the Rust shader library is missing)" ;;
esac
if LC_ALL=C grep -a -qE '/(opt/homebrew|usr/local/Cellar)/' "${FINAL_LIB}"; then
  fail "the merged archive references a Homebrew installation; the iOS build must not link host libraries"
fi

mkdir -p "${OUT_DIR}/include/Platform/Apple" "${OUT_DIR}/include/Core"
cp "${ENGINE_SOURCE}/src/Platform/Apple/SceneWallpaperBindings.h" \
   "${OUT_DIR}/include/Platform/Apple/SceneWallpaperBindings.h"
cp "${ENGINE_SOURCE}/src/Core/RendererCounters.h" "${OUT_DIR}/include/Core/RendererCounters.h"
cat >"${OUT_DIR}/include/WallpaperSceneRenderer.h" <<'EOF'
/*
 * The WallpaperMachine scene renderer C ABI for the iOS host.
 *
 * Include this umbrella from an Objective-C bridging header; it pulls in the
 * engine's own header unchanged. The Swift host at
 * iOS/Sources/Renderer/SceneWallpaperView.swift uses these functions.
 */
#pragma once
#include "Platform/Apple/SceneWallpaperBindings.h"
EOF

cat >"${OUT_DIR}/link-flags.txt" <<EOF
# Link contract for libWallpaperSceneRenderer.a (generated $(date -u +%Y-%m-%dT%H:%M:%SZ)).
# Link the archive once; do not add -force_load and do not link QuickJS,
# FreeType, LZ4 or the Rust shader library separately: they are inside it.
${OUT_DIR}/lib/libWallpaperSceneRenderer.a
-lc++
-framework Accelerate
-framework AudioToolbox
-framework AVFoundation
-framework CoreFoundation
-framework CoreGraphics
-framework CoreMedia
-framework CoreText
-framework CoreVideo
-framework Foundation
-framework ImageIO
-framework IOSurface
-framework Metal
-framework QuartzCore
-framework UIKit
-framework VideoToolbox
EOF

cat >"${OUT_DIR}/Renderer.xcconfig" <<'EOF'
// Generated by scripts/ios/build_renderer.sh.
// The XcodeGen spec is iOS/project.yml, so SRCROOT is the iOS directory.
// Include this from the iOS app target's build configuration, or copy the
// settings into iOS/project.yml. The path and library names are the contract;
// do not link the archive's components separately.
RENDERER_GENERATED_DIR = $(SRCROOT)/Generated/Renderer
RENDERER_LIBRARY_DIR = $(RENDERER_GENERATED_DIR)/lib
SWIFT_OBJC_BRIDGING_HEADER = $(SRCROOT)/Sources/Renderer/SceneWallpaperBridge.h
LIBRARY_SEARCH_PATHS = $(inherited) $(RENDERER_LIBRARY_DIR)
OTHER_LDFLAGS = $(inherited) -lWallpaperSceneRenderer -lc++ -framework Accelerate -framework AudioToolbox -framework AVFoundation -framework CoreFoundation -framework CoreGraphics -framework CoreMedia -framework CoreText -framework CoreVideo -framework Foundation -framework ImageIO -framework IOSurface -framework Metal -framework QuartzCore -framework UIKit -framework VideoToolbox
EOF

manifest_hash="$(shasum -a 256 "${FINAL_LIB}" | awk '{ print $1 }')"
rust_version="$(rustc --version 2>/dev/null || echo unknown)"
clang_version="$("${CC}" --version 2>/dev/null | head -n 1 || echo unknown)"
cat >"${OUT_DIR}/manifest.json" <<EOF
{
  "schema": 1,
  "product": "WallpaperMachineSceneRenderer",
  "platform": "${SDK}",
  "architecture": "${ARCH}",
  "deploymentTarget": "${DEPLOYMENT_TARGET}",
  "configuration": "${CONFIGURATION}",
  "sdkVersion": "${SDK_VERSION}",
  "archive": "lib/libWallpaperSceneRenderer.a",
  "archiveSHA256": "${manifest_hash}",
  "headers": [
    "include/WallpaperSceneRenderer.h",
    "include/Platform/Apple/SceneWallpaperBindings.h",
    "include/Core/RendererCounters.h"
  ],
  "rustTarget": "${RUST_TARGET}",
  "rust": "${rust_version}",
  "clang": "${clang_version}",
  "dependencies": {
    "quickjs-ng": "${QUICKJS_VERSION}",
    "freetype": "${FREETYPE_VERSION}",
    "lz4": "${LZ4_VERSION}",
    "nlohmann-json": "${NLOHMANN_VERSION}",
    "argparse": "${ARGPARSE_VERSION}"
  }
}
EOF

log "built ${FINAL_LIB}"
log "headers in ${OUT_DIR}/include; Xcode settings in ${OUT_DIR}/Renderer.xcconfig"
