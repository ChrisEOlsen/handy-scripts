#!/usr/bin/env bash
# scaffold-name: Metal C++ (Apple silicon GPU)
# scaffold-description: GPU programming with Apple's metal-cpp bindings — CMake, shader build rules, and clangd/Zed flags.
# scaffold-default-name: my_metal_project
#
# Generates:
#   <project>/
#   ├── metal-cpp/              Apple's C++ bindings (downloaded, or a placeholder)
#   ├── main.cpp                your application logic — device setup only
#   ├── mtl_implementation.cpp  the single TU that emits the metal-cpp symbols
#   ├── default.metal           empty shader file, wired into the build
#   ├── CMakeLists.txt          build + shader compilation + a 'run' target
#   ├── compile_flags.txt       clangd/Zed fallback until the build dir exists
#   ├── .gitignore
#   └── README.md
#
# Invoked by main.sh, which exports SCAFFOLD_PROJECT_NAME, SCAFFOLD_TARGET_DIR,
# SCAFFOLD_LIB_DIR and SCAFFOLD_ASSUME_YES.

set -euo pipefail

# shellcheck source=../lib/common.sh
. "${SCAFFOLD_LIB_DIR:?must be run via main.sh}/common.sh"

PROJECT_NAME="${SCAFFOLD_PROJECT_NAME:?}"
TARGET_DIR="${SCAFFOLD_TARGET_DIR:?}"

# Known-good release from Apple's metal-cpp downloads page.
METAL_CPP_URL_DEFAULT="${METAL_CPP_URL:-https://developer.apple.com/metal/cpp/files/metal-cpp_macOS15_iOS18.zip}"
METAL_CPP_PAGE="https://developer.apple.com/metal/cpp/"

# ======================================================= dependency checks ===
# Nothing is installed here — missing tools are reported with the command that
# would fix them.

banner "Checking dependencies"

if [ "$(uname -s)" != "Darwin" ]; then
    log_err "Metal only exists on macOS (this is $(uname -s))."
    ask_yes_no "Generate the project anyway?" "n" || exit 1
elif [ "$(uname -m)" != "arm64" ]; then
    log_warn "Not Apple silicon ($(uname -m)) — Metal works, but this scaffold assumes an arm64 GPU."
fi

check_dep "clang++ (C++ compiler)" \
    "command -v clang++" \
    "xcode-select --install"

check_dep "cmake" \
    "command -v cmake" \
    "brew install cmake"

# CMake's default generator on macOS is Unix Makefiles, so make is still needed
# unless you configure with -G Ninja.
check_dep "make" \
    "command -v make" \
    "xcode-select --install"

check_dep "Xcode command line tools" \
    "xcode-select -p" \
    "xcode-select --install"

# The Metal shader compiler ships with full Xcode, not the CLT. Since Xcode 16
# it is a separately downloaded component.
check_dep "Metal shader compiler (xcrun metal)" \
    "xcrun -sdk macosx metal --version" \
    "xcodebuild -downloadComponent MetalToolchain   # needs full Xcode: xcode-select -s /Applications/Xcode.app"
if [ "$DEP_OK" -eq 0 ]; then
    log_hint "Without it, .metal files can't be compiled into a .metallib. CMake"
    log_hint "skips that step with a note; the C++ side still builds and runs."
fi

check_dep "curl (to download metal-cpp)" \
    "command -v curl" \
    "brew install curl" "optional"

check_dep "unzip (to extract metal-cpp)" \
    "command -v unzip" \
    "brew install unzip" "optional"

check_dep "clangd (IDE completion for Zed)" \
    "command -v clangd" \
    "brew install llvm   # then add \$(brew --prefix llvm)/bin to PATH" "optional"

dep_report

# =============================================================== questions ===

banner "Metal C++ project options"

download_metal_cpp=0
metal_cpp_url="$METAL_CPP_URL_DEFAULT"

if have_cmd curl && have_cmd unzip; then
    if ask_yes_no "Download Apple's metal-cpp bindings now (~5 MB)?" "y"; then
        download_metal_cpp=1
        metal_cpp_url="$(ask "metal-cpp zip URL" "$METAL_CPP_URL_DEFAULT")"
    fi
else
    log_warn "curl/unzip unavailable — metal-cpp/ will be a placeholder."
fi

# =============================================================== generation ==

banner "Creating $PROJECT_NAME"

mkdir -p "$TARGET_DIR"
log_info "$TARGET_DIR"

# ------------------------------------------------------------- metal-cpp ----

fetch_metal_cpp() {
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/metal-cpp.XXXXXX")" || return 1
    _zip="$_tmp/metal-cpp.zip"

    log_info "Downloading metal-cpp from $metal_cpp_url"
    if ! curl -fL --progress-bar -o "$_zip" "$metal_cpp_url"; then
        rm -rf "$_tmp"
        return 1
    fi
    if ! unzip -q "$_zip" -d "$_tmp"; then
        rm -rf "$_tmp"
        return 1
    fi

    # The zip normally contains a top-level metal-cpp/ folder, but don't rely
    # on it — find whichever directory actually holds Metal/Metal.hpp.
    _hdr="$(find "$_tmp" -type f -path '*/Metal/Metal.hpp' -print 2>/dev/null | head -1)"
    if [ -z "$_hdr" ]; then
        log_err "Downloaded archive did not contain Metal/Metal.hpp."
        rm -rf "$_tmp"
        return 1
    fi
    _root="$(dirname "$(dirname "$_hdr")")"

    rm -rf "$TARGET_DIR/metal-cpp"
    mkdir -p "$TARGET_DIR/metal-cpp"
    # Copy the contents of the located root, not the folder itself.
    (cd "$_root" && tar cf - .) | (cd "$TARGET_DIR/metal-cpp" && tar xf -)
    rm -rf "$_tmp"
    return 0
}

metal_cpp_ready=0
if [ "$download_metal_cpp" -eq 1 ]; then
    if fetch_metal_cpp; then
        metal_cpp_ready=1
        log_ok "metal-cpp/ ready ($(find "$TARGET_DIR/metal-cpp" -name '*.hpp' | wc -l | tr -d ' ') headers)"
    else
        log_warn "Download failed — falling back to a placeholder."
        log_hint "Grab the zip yourself from $METAL_CPP_PAGE and extract it to"
        log_hint "$TARGET_DIR/metal-cpp"
    fi
fi

if [ "$metal_cpp_ready" -eq 0 ] && [ ! -f "$TARGET_DIR/metal-cpp/Metal/Metal.hpp" ]; then
    mkdir -p "$TARGET_DIR/metal-cpp"
    write_file "$TARGET_DIR/metal-cpp/PUT_METAL_CPP_HERE.md" <<EOF
# metal-cpp goes here

This folder is a placeholder. Download the bindings from

    $METAL_CPP_PAGE

pick the release matching your macOS SDK, unzip it, and replace this folder with
the extracted \`metal-cpp\` directory so that these paths exist:

    metal-cpp/Foundation/Foundation.hpp
    metal-cpp/Metal/Metal.hpp
    metal-cpp/QuartzCore/QuartzCore.hpp

From the command line:

    curl -L -o /tmp/metal-cpp.zip "$METAL_CPP_URL_DEFAULT"
    unzip -q /tmp/metal-cpp.zip -d /tmp
    rm -rf metal-cpp && mv /tmp/metal-cpp .

Then delete this file and run:

    cmake -S . -B build && cmake --build build --target run
EOF
fi

# --------------------------------------------------------------- sources ----

write_file "$TARGET_DIR/mtl_implementation.cpp" <<'EOF'
// mtl_implementation.cpp
//
// metal-cpp is a header-only wrapper, but exactly ONE translation unit in the
// program has to emit the actual symbols. These three defines do that, so this
// file must stay separate from any other source and must never be included by
// another file. Everywhere else, just #include the headers normally.
//
// It is slow to compile and almost never changes, so keeping it alone in its
// own object file means you only pay for it once.

#define NS_PRIVATE_IMPLEMENTATION
#define CA_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <QuartzCore/QuartzCore.hpp>
EOF

write_file "$TARGET_DIR/default.metal" <<'EOF'
// default.metal — compiled into default.metallib next to the binary.
// Every *.metal file in this directory is picked up automatically.

#include <metal_stdlib>
using namespace metal;
EOF

write_file "$TARGET_DIR/main.cpp" <<'EOF'
// main.cpp

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>

#include <cstdio>

int main()
{
    // Objects from metal-cpp factory methods (commandBuffer(),
    // computeCommandEncoder(), ...) are autoreleased into this pool. Objects
    // from new* methods are owned by you — release() them yourself.
    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();

    MTL::Device* device = MTL::CreateSystemDefaultDevice();
    if (!device) {
        std::fprintf(stderr, "no Metal device available\n");
        pool->release();
        return 1;
    }
    std::printf("%s\n", device->name()->utf8String());

    device->release();
    pool->release();
    return 0;
}
EOF

# ---------------------------------------------------------- CMakeLists ------

write_file "$TARGET_DIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(__PROJECT_NAME__ LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Feeds clangd (Zed, VS Code, nvim). Honoured by the Makefile and Ninja
# generators; the Xcode generator ignores it, so configure a Ninja/Makefile
# build dir too if you mainly work in Xcode.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT APPLE)
    message(FATAL_ERROR "Metal is macOS only.")
endif()

if(NOT EXISTS "${CMAKE_SOURCE_DIR}/metal-cpp/Metal/Metal.hpp")
    message(FATAL_ERROR
        "metal-cpp headers not found in ./metal-cpp — download them from "
        "https://developer.apple.com/metal/cpp/ and extract them there (see README.md).")
endif()

# Header-only bindings. SYSTEM keeps -Wall/-Wextra from flagging Apple's headers.
add_library(metal-cpp INTERFACE)
target_include_directories(metal-cpp SYSTEM INTERFACE "${CMAKE_SOURCE_DIR}/metal-cpp")

add_executable(${PROJECT_NAME}
    main.cpp
    mtl_implementation.cpp
)

target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra)

find_library(FOUNDATION_LIBRARY Foundation REQUIRED)
find_library(METAL_LIBRARY Metal REQUIRED)
find_library(QUARTZCORE_LIBRARY QuartzCore REQUIRED)

target_link_libraries(${PROJECT_NAME} PRIVATE
    metal-cpp
    ${FOUNDATION_LIBRARY}
    ${METAL_LIBRARY}
    ${QUARTZCORE_LIBRARY}
)

# ---------------------------------------------------------------- shaders ---
# CMake has no native Metal support, so every *.metal is compiled to .air and
# linked into one default.metallib by hand. The shader compiler ships with full
# Xcode, not the command line tools — if it is missing, skip the step with a
# note rather than failing the whole build.

execute_process(
    COMMAND xcrun -sdk macosx --find metal
    OUTPUT_VARIABLE METAL_COMPILER
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE METAL_COMPILER_MISSING
    ERROR_QUIET
)

file(GLOB METAL_SOURCES CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/*.metal")

if(METAL_COMPILER_MISSING OR NOT METAL_SOURCES)
    message(STATUS "Metal shader compiler not found — skipping .metallib.")
    message(STATUS "  install: xcodebuild -downloadComponent MetalToolchain")
else()
    set(AIR_FILES "")
    foreach(shader ${METAL_SOURCES})
        get_filename_component(shader_name "${shader}" NAME_WE)
        set(air "${CMAKE_CURRENT_BINARY_DIR}/${shader_name}.air")
        add_custom_command(
            OUTPUT "${air}"
            COMMAND xcrun -sdk macosx metal -c "${shader}" -o "${air}"
            DEPENDS "${shader}"
            COMMENT "Compiling shader ${shader_name}.metal"
            VERBATIM
        )
        list(APPEND AIR_FILES "${air}")
    endforeach()

    set(METALLIB "${CMAKE_CURRENT_BINARY_DIR}/default.metallib")
    add_custom_command(
        OUTPUT "${METALLIB}"
        COMMAND xcrun -sdk macosx metallib ${AIR_FILES} -o "${METALLIB}"
        DEPENDS ${AIR_FILES}
        COMMENT "Linking default.metallib"
        VERBATIM
    )
    add_custom_target(shaders DEPENDS "${METALLIB}")
    add_dependencies(${PROJECT_NAME} shaders)

    # Put it next to the executable, which is a different directory under the
    # Xcode generator than under Ninja/Makefiles.
    add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${METALLIB}" "$<TARGET_FILE_DIR:${PROJECT_NAME}>/default.metallib"
        VERBATIM
    )
endif()

# Keep clangd happy without pointing it into build/: symlink the compilation
# database next to the sources. Harmless if it is already there.
if(CMAKE_EXPORT_COMPILE_COMMANDS AND NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    file(CREATE_LINK
        "${CMAKE_BINARY_DIR}/compile_commands.json"
        "${CMAKE_SOURCE_DIR}/compile_commands.json"
        SYMBOLIC
    )
endif()

# `cmake --build build --target run`
add_custom_target(run
    COMMAND "$<TARGET_FILE:${PROJECT_NAME}>"
    DEPENDS ${PROJECT_NAME}
    WORKING_DIRECTORY "$<TARGET_FILE_DIR:${PROJECT_NAME}>"
    USES_TERMINAL
)
EOF
sed -i '' "s/__PROJECT_NAME__/$PROJECT_NAME/g" "$TARGET_DIR/CMakeLists.txt"

# ------------------------------------------------------ IDE / clangd flags ---
# CMake writes a compile_commands.json and symlinks it into the project root,
# and clangd prefers that. This file is the fallback for the window before the
# build directory has been configured — one argument per line, with the sysroot
# baked in from this machine's SDK.

SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"

{
    cat <<'EOF'
-xc++
-std=c++17
-Wall
-Wextra
-I.
-Imetal-cpp
EOF
    if [ -n "$SDK_PATH" ]; then
        printf -- '-isysroot\n%s\n' "$SDK_PATH"
    fi
} > "$TARGET_DIR/compile_flags.txt"
log_add "compile_flags.txt"
[ -n "$SDK_PATH" ] || log_warn "Could not determine the SDK path — compile_flags.txt has no -isysroot."

write_file "$TARGET_DIR/.gitignore" <<'EOF'
build/
build-*/
*.air
*.metallib
*.o
*.d
.DS_Store
.cache/
compile_commands.json
DerivedData/
*.gputrace

# metal-cpp is a third-party download; uncomment to keep it out of the repo.
# metal-cpp/
EOF

# ----------------------------------------------------------------- README ---

write_file "$TARGET_DIR/README.md" <<EOF
# $PROJECT_NAME

GPU compute with Apple's [metal-cpp]($METAL_CPP_PAGE) bindings on Apple silicon.

## Layout

\`\`\`
$PROJECT_NAME/
├── metal-cpp/              Apple's C++ bindings (third-party download)
├── main.cpp                your code — gets a device, nothing else
├── mtl_implementation.cpp  the one TU that emits metal-cpp's symbols
├── default.metal           empty; every *.metal here is built into the metallib
├── CMakeLists.txt
└── compile_flags.txt       clangd fallback until build/ has been configured
\`\`\`

## Build

\`\`\`sh
cmake -S . -B build
cmake --build build
./build/$PROJECT_NAME

# or in one step
cmake --build build --target run
\`\`\`

\`default.metallib\` is built next to the binary, so run from that directory or
pass an absolute path when you load it. If the Metal shader compiler is not
installed, CMake says so at configure time and skips the metallib; the C++ side
still builds. Load it with
\`device->newLibrary(NS::URL::fileURLWithPath(...), &error)\`.

### Xcode (GPU frame capture, shader debugger)

Needs full Xcode selected — with only the command line tools, CMake rejects the
generator ("Xcode 1.5 not supported").

\`\`\`sh
sudo xcode-select -s /Applications/Xcode.app
cmake -S . -B build-xcode -G Xcode
open build-xcode/$PROJECT_NAME.xcodeproj
\`\`\`

Keep the regular \`build/\` dir around as well — the Xcode generator does not
write \`compile_commands.json\`, so clangd needs the other one.

## Requirements

| Tool | Install |
| --- | --- |
| CMake | \`brew install cmake\` |
| Command line tools | \`xcode-select --install\` |
| Metal shader compiler | \`xcodebuild -downloadComponent MetalToolchain\` (needs full Xcode) |
| metal-cpp | download from $METAL_CPP_PAGE, extract into \`metal-cpp/\` |

## Notes

- Only \`mtl_implementation.cpp\` defines \`*_PRIVATE_IMPLEMENTATION\`. Defining
  those anywhere else gives you duplicate-symbol link errors.
- Objects from \`new*\` methods are owned by you — \`release()\` them. Objects
  from factory methods (\`commandBuffer()\`, \`computeCommandEncoder()\`) are
  autoreleased; the \`NS::AutoreleasePool\` in \`main\` handles them.
- An \`NS::Error*\` returned through an out-parameter is autoreleased too.
  Releasing it is an over-release and segfaults when the pool drains — a
  confusing crash, because it happens nowhere near the offending line.
- Configuring symlinks \`build/compile_commands.json\` into the project root,
  which is what clangd actually uses. \`compile_flags.txt\` is only the fallback
  for before you have configured — clangd prefers the compilation database when
  both are present. Delete \`compile_flags.txt\` if you would rather not keep two
  sources of flags.
- If Zed still shows red lines, restart it after \`metal-cpp/\` is populated or
  after the first configure.
EOF

# ============================================================== next steps ===

banner "Next steps"
printf '  cd %s\n' "$TARGET_DIR"
if [ ! -f "$TARGET_DIR/metal-cpp/Metal/Metal.hpp" ]; then
    printf '  %s# download metal-cpp first — see metal-cpp/PUT_METAL_CPP_HERE.md%s\n' "$C_YELLOW" "$C_RESET"
fi
printf '  cmake -S . -B build\n'
printf '  cmake --build build --target run\n'
