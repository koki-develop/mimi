#!/usr/bin/env bash
# Builds CEchoCanceller.xcframework: WebRTC AEC3 from webrtc-audio-processing behind the C interface in include/.
# Requires meson and ninja on PATH (provided by mise).
set -euo pipefail

version="2.1"
sha256="ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe"
url="https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-${version}.tar.xz"
deployment_target="26.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build="${root}/build"
work="${build}/work"
output="${build}/CEchoCanceller.xcframework"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: building requires Apple Silicon (arm64)" >&2
  exit 1
fi

rm -rf "${work}"
mkdir -p "${work}"

archive="${work}/webrtc-audio-processing-${version}.tar.xz"
curl --fail --location --silent --show-error --output "${archive}" "${url}"
echo "${sha256}  ${archive}" | shasum -a 256 --check --status || {
  echo "error: checksum mismatch for ${url}" >&2
  exit 1
}
tar -xf "${archive}" -C "${work}"
source_dir="${work}/webrtc-audio-processing-${version}"
meson_dir="${work}/meson"

export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET="${deployment_target}"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
export AR="$(xcrun --find ar)"

# Always builds the bundled abseil, which is linked into the framework below, rather than any found on the system.
meson setup "${meson_dir}" "${source_dir}" \
  --buildtype=release \
  --default-library=static \
  --force-fallback-for=abseil-cpp \
  -Db_ndebug=true
meson compile -C "${meson_dir}"

"${CXX}" -c "${root}/echo_canceller.cc" -o "${work}/echo_canceller.o" \
  -std=c++17 -O3 -arch arm64 -mmacosx-version-min="${deployment_target}" \
  -DNDEBUG -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_ARCH_ARM64 -DWEBRTC_APM_DEBUG_DUMP=0 \
  -I "${root}/include" \
  -I "${source_dir}/webrtc" \
  -I "${meson_dir}/webrtc" \
  -I "${source_dir}/subprojects/abseil-cpp-20240722.0"

# Links the interface and everything it uses into one object, keeping only the interface visible,
# so that the bundled WebRTC and abseil symbols cannot clash with other code in the app.
libraries=("${meson_dir}/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a")
while IFS= read -r library; do
  libraries+=("${library}")
done < <(find "${meson_dir}" -name '*.a' ! -name 'libwebrtc-audio-processing-2.a' | sort)
"${CXX}" -r -nostdlib -arch arm64 -mmacosx-version-min="${deployment_target}" \
  -Wl,-exported_symbols_list,"${root}/exported_symbols.txt" \
  -o "${work}/CEchoCanceller.o" "${work}/echo_canceller.o" "${libraries[@]}"

mkdir -p "${work}/lib"
xcrun libtool -static -o "${work}/lib/libCEchoCanceller.a" "${work}/CEchoCanceller.o"
xcodebuild -create-xcframework \
  -library "${work}/lib/libCEchoCanceller.a" \
  -headers "${root}/include" \
  -output "${work}/CEchoCanceller.xcframework"

# Replaces the previous framework only once the new one is complete, so a failed build leaves it usable.
rm -rf "${output}"
mv "${work}/CEchoCanceller.xcframework" "${output}"
rm -rf "${work}"
