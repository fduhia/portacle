#!/bin/bash
set -uo pipefail

## Determine the OS type
case "$OSTYPE" in
    linux-gnu) OS="lin" ;;
    darwin*)   OS="mac" ;;
    cygwin)    OS="win" ;;
    msys)      OS="win" ;;
    win32)     OS="win" ;;
    freebsd)   OS="bsd" ;;
    *)         OS="any" ;;
esac

## Use autodetect if unspecified
PLATFORM=${PLATFORM:-$OS}

## OS X' readlink does not support -f, substitute our own
function mreadlink() {
    case "$PLATFORM" in 
        mac) python -c 'import os, sys; print os.path.realpath(sys.argv[1])' $1 ;;
        *)   readlink -f $1 ;;
    esac
}

## Autodetect other variables
SCRIPT_DIR=${SCRIPT_DIR:-$(mreadlink $(dirname $0))}
SOURCE_DIR=${SOURCE_DIR:-$SCRIPT_DIR/$PROGRAM/}
PORTACLE_DIR=${PORTACLE_DIR:-$(mreadlink $SCRIPT_DIR/../)}
SHARED_DIR=${SHARED_DIR:-$PORTACLE_DIR/$PLATFORM}
SHARED_BIN_DIR=${SHARED_BIN_DIR:-$SHARED_DIR/bin}
SHARED_LIB_DIR=${SHARED_LIB_DIR:-$SHARED_DIR/lib}
INSTALL_DIR=${INSTALL_DIR:-$PORTACLE_DIR/$PLATFORM/${PROGRAM}/}
FRAGMENT_FILE=${FRAGMENT_FILE:-$SCRIPT_DIR/.portacle-finished-fragments}
_DEFAULT_TARGETS=(download prepare build install)
DEFAULT_TARGETS=("${DEFAULT_TARGETS[@]:-${_DEFAULT_TARGETS[@]}}")
TARGETS=("${@:-${DEFAULT_TARGETS[@]}}")
CFLAGS=${CFLAGS:-}
CXXFLAGS=${CXXFLAGS:-}
LDFLAGS=${LDFLAGS:-}
FORCE=${FORCE:-}

## Automatically force if we explicitly specified ops.
if [ "$#" -ne 0 ]; then
    FORCE=1
fi

## Determine mac cpu count
case "$PLATFORM" in
    win) MAXCPUS=$NUMBER_OF_PROCESSORS ;;
    lin) MAXCPUS=${MAXCPUS:-$(cat /proc/cpuinfo | awk '/^processor/{print $3}' | tail -1)} ;;
    *)   MAXCPUS=${MAXCPUS:-1} ;;
esac

## Find all the dynamic libraries we need to care about
function nonlocal-ldd() {
    case "$PLATFORM" in
        win) ldd "$1"      | awk '{print $3}' | grep -E '^/[^/]{2,}/' ;;
        mac) otool -L "$1" | awk '{print $1}' | grep -E '/opt/local/lib|/usr/local/lib' ;;
        lin) ldd "$1"      | awk '{print $3}' | grep -E '^/' ;;
    esac
}

## Sort and strip all duplicates from the arguments
function uniquify() {
    echo "$@" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

function system-has() {
    hash "$1" 2>/dev/null
}

function contains() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

function win-exes-for-package(){
    pacman -Ql "$1" | grep "\\.exe" | awk '{print $2}'
}

function to-win-path() {
    local result=()
    for file in "$@"; do
        result+=($(cygpath -w "$file"))
    done
    echo "${result[@]}"
}

function from-win-path() {
    local result=()
    for file in "$@"; do
        result+=($(cygpath -u "$file"))
    done
    echo "${result[@]}"
}

## Compute the full dependency list for the given input file
function compute-dependencies() {
    local deps=( $(nonlocal-ldd $1) )
    local fulldeps=( "${deps[@]+${deps[@]}}" "${@:2}" )
    for dep in "${deps[@]+${deps[@]}}"; do
        if ! contains "$dep" "${fulldeps[@]}"; then
            local newdeps=$(compute-dependencies "$dep")
            fulldeps=( "${fulldeps[@]}" "${newdeps[@]}" )
        fi
    done
    uniquify "${fulldeps[@]+${fulldeps[@]}}"
}

function ucp() {
    if system-has rsync; then
        rsync -aqz "$@"
    else
        case "$PLATFORM" in
            mac) cp -Rf "$@" ;;
            *)   cp -Rfu "$@" ;;
        esac
    fi
}

## To avoid recompilation of finished components
function finish-stage() {
    echo "$PROGRAM $TAG $1" >> "$FRAGMENT_FILE"
}

function stage-finished() {
    grep -qF "$PROGRAM $TAG $1" "$FRAGMENT_FILE" 2>/dev/null
}

function clean-fragments() {
    case "$PLATFORM" in
        mac) gsed -i'' "/$PROGRAM $TAG/d" "$FRAGMENT_FILE" ;;
        *)   sed -i'' "/$PROGRAM $TAG/d" "$FRAGMENT_FILE" ;;
    esac
}

## Ensure the given array of files is copied to the target directory
function ensure-installed() {
    local target=$1
    local files=( "${@:2}" )
    mkdir -p "$target"
    for file in "${files[@]+${files[@]}}"; do
        local name=$(basename "$file")
        local realfile=$(mreadlink "$file")
        eecho "Copying $file"
        ucp "$realfile" "$target/$name"
    done
}

function ensure-dependencies() {
    mkdir -p "$SHARED_LIB_DIR/"
    for file in "$@"; do
        ensure-installed "$SHARED_LIB_DIR/" $(compute-dependencies "$file")
    done
}

function find-binaries() {
    case "$PLATFORM" in
        win) find "$1" -name "*.exe" -type f -executable -print ;;
        mac) find "$1" -type f -perm +111 -exec sh -c "file '{}' | grep -q '64-bit executable'" \; -print ;;
        lin) find "$1" -type f -executable -exec sh -c "file -i '{}' | grep -q 'x-executable; charset=binary'" \; -print ;;
    esac
}

## This does not need explanation
function eecho() {
    echo $@ >&2
}

function eexit() {
    echo "$(tput setaf 1) ! Error: $(tput sgr 0)" $@
    exit 1
}

function status() {
    local level=$1
    case "$level" in
        0) echo "$(tput setaf 2) ==> $(tput sgr 0)" ${@:2};;
        1) echo "$(tput setaf 3)   -> $(tput sgr 0)" ${@:2};;
        *) echo "$(tput setaf 6)     > $(tput sgr 0)" ${@:2};;
    esac
}

## Following here are standard implementations for the various stages
function info() {
    status 0 "${PROGRAM} build info:"
    echo "Platform:           ${PLATFORM}
Downloading from:   ${REPOSITORY}
Using tag:          ${TAG}
Building in:        ${SOURCE_DIR}
Installing into:    ${INSTALL_DIR}
Using threads:      ${MAXCPUS}
Building targets:   ${TARGETS[@]}
"
}

function download() {
    if [ -z "$REPOSITORY" ]; then
        status 2 "skipping download"
        return 0
    fi
    
    mkdir -p "$SOURCE_DIR" &> /dev/null
    if [ -d "$SOURCE_DIR/.git" ]; then
        cd "$SOURCE_DIR"
        git reset --hard HEAD
        git clean -fdx
        git fetch origin master\
            || eexit "Failed to download source."
        git checkout origin/master\
            || eexit "Failed to check out master source."
    elif [ -n "$TAG" ]; then
        git clone "$REPOSITORY" "$SOURCE_DIR" --branch="$TAG" --depth=1 \
            || eexit "Failed to download source."
    else
        git clone "$REPOSITORY" "$SOURCE_DIR" --depth=1 \
            || eexit "Failed to download source."
    fi
    cd "$SOURCE_DIR"
    if [ -n "$TAG" ]; then
       git checkout tags/$TAG \
           || eexit "Failed to checkout desired tag."
    fi
    finish-stage download
}

function prepare (){
    status 2 "skipping prepare, not needed"
}

function build (){
    status 2 "skipping build, not needed"
}

function install (){
    status 2 "skipping install, not needed"
}

function clean() {
    rm -rf "$SOURCE_DIR"
    clean-fragments
}

function clean-installed() {
    cd "$INSTALL_DIR"
    rm -R ./*/
}

function main() {
    info
    if [ ! -z "$FORCE" ]; then
       clean-fragments
    fi
    
    for TARGET in "${TARGETS[@]}"; do
            status 1 "${TARGET}ing $PROGRAM"
        if stage-finished "$TARGET"; then
            status 2 "skipping $TARGET, already completed"
        else
            $TARGET || exit 1
            finish-stage "$TARGET"
        fi
    done
    status 0 "$PROGRAM done"
}
