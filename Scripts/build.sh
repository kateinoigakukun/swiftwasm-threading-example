#!/usr/bin/env bash
set -eo pipefail

if [ -z "$USE_SWIFT_SDK_ID" ]; then
  exec "$(dirname "$0")/use-swift.sh" $0 "$@"
fi

DEPLOY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy)
      DEPLOY=1
      ;;
    --help)
      echo "Usage: $0 [--deploy]"
      echo "  --deploy: Optimize the output for deployment"
      exit 0
      ;;
    *)
      break
      ;;
  esac
  shift
done

swift build -c release -Xswiftc -g --swift-sdk "$USE_SWIFT_SDK_ID" \
  -Xswiftc -Xclang-linker \
  -Xswiftc -mexec-model=reactor \
  -Xlinker --export=__main_argc_argv

mkdir -p static
if [ $DEPLOY -eq 1 ]; then
  echo "Optimizing WebAssembly binary..."
  wasm-opt --strip-debug .build/release/MyApp.wasm -o static/MyApp.wasm
else
  cp .build/release/MyApp.wasm static/MyApp.wasm
fi

echo "Generating metadata for WebAssembly memory size..."
swift run --package-path ./Tools Tools ./static/MyApp.wasm static/wasm.meta.json

PATH_TO_COPY=(
  JavaScriptKit_JavaScriptKit.resources/Runtime/index.mjs
)
for path in "${PATH_TO_COPY[@]}"; do
  echo "Copying $path..."
  mkdir -p "static/$(dirname "$path")"
  rm -rf "static/$path"
  cp -r ".build/release/$path" "static/$path"
done
