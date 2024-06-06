#!/usr/bin/env bash
#
# This script does the following:
# 1. Install Swift toolchain based on ./.swift-version file if not already installed
# 2. Update ./Toolchains/swift-latest symlink to point to the latest installed Swift toolchain
# 3. Execute the given command with PATH set to the Swift toolchain bin directory

set -eo pipefail

SWIFT_VERSION_FILE=".swift-version"
SWIFT_TOOLCHAIN_MANIFEST="swift-toolchain"
INITIAL_PWD="$PWD"

info() {
  printf "\e[1;32minfo:\e[0m $1\n" >&2
}

fatal() {
  printf "\e[1;31merror:\e[0m $1\n" >&2
  exit 1
}

fatal-with-manual-toolchain-url-guide() {
  printf "\e[1;31merror:\e[0m $1\n" >&2
  printf "You can still specify URL to download Swift toolchain manually using USE_SWIFT_TOOLCHAIN_URL environment variable.

Example:
  export USE_SWIFT_TOOLCHAIN_URL=\"https://github.com/swiftwasm/swift/releases/download/swift-wasm-DEVELOPMENT-SNAPSHOT-2024-04-19-a/swift-wasm-DEVELOPMENT-SNAPSHOT-2024-04-19-a-macos_arm64.pkg\"


" >&2
  exit 1
}

check-swift-version-file() {
  if [ ! -f "$SWIFT_VERSION_FILE" ]; then
    fatal "Swift version file $SWIFT_VERSION_FILE not found"
  fi
}

detect-swift-arch-suffix() {
  case "$(uname -m)" in
    x86_64)
      echo ""
      ;;
    arm64 | aarch64)
      echo "-aarch64"
      ;;
    *)
      fatal-with-manual-toolchain-url-guide "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

detect-swift-platform() {
  local name=""
  local full_name=""
  local arch_suffix="$(detect-swift-arch-suffix)"
  local package_extension="tar.gz"

  case "$(uname -s)" in
    Darwin)
      name="xcode"
      full_name="osx"
      # macOS toolchain is universal
      arch_suffix=""
      package_extension="pkg"
      ;;
    Linux)
      if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
          ubuntu)
            case "$VERSION_ID" in
              18.04)
                name="ubuntu1804"
                full_name="ubuntu18.04"
                ;;
              20.04)
                name="ubuntu2204"
                full_name="ubuntu20.04"
                ;;
              22.04)
                name="ubuntu2204"
                full_name="ubuntu22.04"
                ;;
              *)
                fatal-with-manual-toolchain-url-guide "Unsupported Ubuntu version: $VERSION_ID"
                ;;
            esac
            ;;
          centos)
            case "$VERSION_ID" in
              7)
                name="centos7"
                full_name="centos7"
                ;;
              *)
                fatal-with-manual-toolchain-url-guide "Unsupported CentOS version: $VERSION_ID"
                ;;
            esac
            ;;
          amzn)
            case "$VERSION_ID" in
              2)
                name="amazonlinux2"
                full_name="amazonlinux2"
                ;;
              *)
                fatal-with-manual-toolchain-url-guide "Unsupported Amazon Linux version: $VERSION_ID"
                ;;
            esac
            ;;
          rhel)
            case "$VERSION_ID" in
              9)
                name="ubi9"
                full_name="ubi9"
                ;;
              *)
                fatal-with-manual-toolchain-url-guide "Unsupported RHEL version: $VERSION_ID"
                ;;
            esac
            ;;
          *)
            fatal-with-manual-toolchain-url-guide "Unsupported Linux distribution: $ID"
            ;;
        esac
      else
        fatal-with-manual-toolchain-url-guide "Unsupported Linux distribution"
      fi
      ;;
    *)
      fatal-with-manual-toolchain-url-guide "Unsupported platform: $(uname -s)"
      ;;
  esac
  echo "name=$name full_name=$full_name arch_suffix=$arch_suffix package_extension=$package_extension"
}

detect-swift-download-channel() {
  # DEVELOPMENT-SNAPSHOT-2024-04-22-a -> development
  # 6.0-DEVELOPMENT-SNAPSHOT-2024-04-22-a -> swift-6.0-branch
  # 5.10-RELEASE -> swift-5.10-release
  local version="$1"
  case "$version" in
    wasm-*)
      fatal "WebAssembly toolchain is not supported by this script. Please use swift.org toolchain with Swift SDK"
      ;;
    DEVELOPMENT-SNAPSHOT-*)
      echo "development"
      ;;
    *-DEVELOPMENT-SNAPSHOT-*)
      echo "swift-$(echo $version | cut -d- -f1)-branch"
      ;;
    *-RELEASE)
      echo "swift-$(echo $version | cut -d- -f1)-release"
      ;;
    *)
      fatal-with-manual-toolchain-url-guide "Unsupported Swift version: $version"
      exit 1
      ;;
  esac
}

swift-toolchain-download-url() {
  local version="$1"

  if [ -n "$USE_SWIFT_TOOLCHAIN_URL" ]; then
    info "Using Swift toolchain URL from USE_SWIFT_TOOLCHAIN_URL environment variable"
    echo "$USE_SWIFT_TOOLCHAIN_URL"
  else
    eval "$(detect-swift-platform)"
    if [ -z "$name" ] || [ -z "$full_name" ] || [ -z "$package_extension" ]; then
      exit 1
      return
    fi
    read -r channel < <(detect-swift-download-channel "$version")
    if [ -z "$channel" ]; then
      exit 1
      return
    fi
    local tag="swift-$version"
    echo "https://download.swift.org/$channel/$name$arch_suffix/$tag/$tag-$full_name$arch_suffix.$package_extension"
  fi
}

swift-toolchain-install-dir() {
  local version="$1"
  echo "$INITIAL_PWD/Toolchains/swift-$version"
}

install-swift-toolchain() {
  local version="$1"
  local SWIFT_TOOLCHAIN_DIR=$(swift-toolchain-install-dir "$version")
  if [ -d "$SWIFT_TOOLCHAIN_DIR" ]; then
    info "Swift toolchain $version is already installed at $SWIFT_TOOLCHAIN_DIR"
    return
  fi

  local url
  url=$(swift-toolchain-download-url "$version")

  if [ -z "$url" ]; then
    exit 1
  fi

  local tmp_dir=$(mktemp -d)
  local package_name=$(basename $url)
  local package_path="$tmp_dir/$package_name"

  info "Downloading Swift toolchain $version from $url"
  curl -L -o $package_path $url

  if [ -f "$package_path" ]; then
    info "Installing Swift toolchain $version to $SWIFT_TOOLCHAIN_DIR"
    mkdir -p "$(dirname $SWIFT_TOOLCHAIN_DIR)"

    case "$package_name" in
      *.tar.gz)
        local tmp_extract_dir=$(mktemp -d)
        tar -xzf $package_path -C $tmp_extract_dir --strip-components=1
        mv $tmp_extract_dir "$SWIFT_TOOLCHAIN_DIR"
        ;;
      *.pkg)
        installer -pkg $package_path -target CurrentUserHomeDirectory
        ln -s "$HOME/Library/Developer/Toolchains/swift-$version.xctoolchain" "$SWIFT_TOOLCHAIN_DIR"

        # WORKAROUND: Strip hardened runtime flag from Swift binaries
        # See https://github.com/apple/swift/issues/73327#issuecomment-2120481479
        echo "Stripping hardened runtime flag from Swift binaries..."
        find "$SWIFT_TOOLCHAIN_DIR/usr/bin" -type f | \
          while read line; do
            codesign --force --preserve-metadata=identifier,entitlements --sign - $line 2>/dev/null || true
          done
        ;;
      *)
        fatal "Unsupported package format: $package_name"
        ;;
    esac

    update-latest-swift-toolchain "$SWIFT_VERSION"
  else
    fatal "Failed to download Swift toolchain from $url"
  fi
}

# Update symlink to the latest installed Swift toolchain
update-latest-swift-toolchain() {
  local SWIFT_TOOLCHAIN_DIR=$(swift-toolchain-install-dir "$1")
  rm -f "$INITIAL_PWD/Toolchains/swift-latest"
  ln -sf "$SWIFT_TOOLCHAIN_DIR" "$INITIAL_PWD/Toolchains/swift-latest"
}

# Execute the given command with PATH set to the Swift toolchain bin directory
execute-with-swift-toolchain-path() {
  local SWIFT_TOOLCHAIN_DIR=$(swift-toolchain-install-dir "$1")
  shift
  local env_vars=()
  env_vars+=("PATH=$SWIFT_TOOLCHAIN_DIR/usr/bin:$PATH")
  env_vars+=("USE_SWIFT_TOOLCHAIN_DIR=$SWIFT_TOOLCHAIN_DIR")
  env_vars+=("USE_SWIFT_SDK_ID=$(get-swift-sdk-id-from-manifest)")

  # WORKAROUND: The latest Swift toolchain from the main branch has an issue
  # with OS-bundled Swift runtime libraries on macOS.
  # See https://github.com/apple/swift/issues/73327#issuecomment-2120481479
  if [ "$(uname -s)" == "Darwin" ]; then
    local swift_lib_dir="$SWIFT_TOOLCHAIN_DIR/usr/lib/swift/macosx"
    env_vars+=("DYLD_LIBRARY_PATH=$swift_lib_dir")
    # Define with USE_SWIFT_ prefix to make it pass through to the child processes
    # even though those child executables are hardened runtime enabled.
    env_vars+=("USE_SWIFT_DYLD_LIBRARY_PATH=$swift_lib_dir")
  fi

  env "${env_vars[@]}" "$@"
}

install-swift-sdk() {
  local swift_version="$1"
  local id="$2"
  local triple="$3"
  local url="$4"
  execute-with-swift-toolchain-path "$swift_version" swift experimental-sdk list | grep -q "$id" && return
  local install_command=(swift experimental-sdk install "$url")
  info "Installing Swift SDK $id: ${install_command[*]}"
  execute-with-swift-toolchain-path "$swift_version" "${install_command[@]}"
}

# Install Swift SDK from the ./swift-toolchain definition
install-swift-sdk-from-manifest() {
  local swift_version="$1"
  shift
  swift-sdk() { install-swift-sdk "$swift_version" "$@"; }
  source "$SWIFT_TOOLCHAIN_MANIFEST"
}

# Get Swift SDK id from the ./swift-toolchain definition
get-swift-sdk-id-from-manifest() {
  local SWIFT_TOOLCHAIN_DIR=$(swift-toolchain-install-dir "$1")
  shift
  swift-sdk() { echo "$1"; }
  source "$SWIFT_TOOLCHAIN_MANIFEST"
}

check-swift-version-file
SWIFT_VERSION=$(cat $SWIFT_VERSION_FILE)
install-swift-toolchain "$SWIFT_VERSION"
if [ -f "$SWIFT_TOOLCHAIN_MANIFEST" ]; then
  install-swift-sdk-from-manifest "$SWIFT_VERSION"
fi

if [ "$#" -eq 0 ]; then
  exit 0
fi
execute-with-swift-toolchain-path "$SWIFT_VERSION" "$@"
