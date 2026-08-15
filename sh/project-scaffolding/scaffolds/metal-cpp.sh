#!/usr/bin/env bash
# scaffold-name: Metal C++ (Apple silicon GPU)
# scaffold-description: GPU programming with Apple's metal-cpp bindings — Makefile, shader build rules, and clangd/Zed flags.
# scaffold-default-name: my_metal_project
#
# Generates:
#   <project>/
#   ├── metal-cpp/              Apple's C++ bindings (downloaded, or a placeholder)
#   ├── main.cpp                your application logic — device setup only
#   ├── mtl_implementation.cpp  the single TU that emits the metal-cpp symbols
#   ├── default.metal           empty shader file, wired into the build
#   ├── Makefile                build + shader compilation + run + clean
#   ├── compile_flags.txt       clangd/Zed include paths, so no phantom red lines
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
    log_hint "Without it, .metal files can't be precompiled into a .metallib."
    log_hint "'make' skips that step with a note; the C++ side still builds and runs."
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

Then delete this file and run \`make run\`.
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
// default.metal — compiled into build/default.metallib by `make shaders`.
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

# --------------------------------------------------------------- Makefile ---

write_file "$TARGET_DIR/Makefile" <<'EOF'
# Makefile — __PROJECT_NAME__

TARGET   := __PROJECT_NAME__
BUILD    := build

CXX      := clang++
METAL    := xcrun -sdk macosx metal
METALLIB := xcrun -sdk macosx metallib

CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -I. -Imetal-cpp
LDFLAGS  := -framework Foundation -framework Metal -framework QuartzCore

SRCS     := main.cpp mtl_implementation.cpp
OBJS     := $(SRCS:%.cpp=$(BUILD)/%.o)
DEPS     := $(OBJS:.o=.d)

SHADERS  := $(wildcard *.metal)
AIRS     := $(SHADERS:%.metal=$(BUILD)/%.air)
LIBRARY  := $(BUILD)/default.metallib

BIN      := $(BUILD)/$(TARGET)

# Fail early with a readable message instead of 400 lines of missing headers.
ifneq ($(MAKECMDGOALS),clean)
ifeq ($(wildcard metal-cpp/Metal/Metal.hpp),)
$(error metal-cpp headers not found in ./metal-cpp — download them from https://developer.apple.com/metal/cpp/ and extract them there (see README.md))
endif
endif

.PHONY: all run shaders clean help

all: $(BIN) shaders

$(BIN): $(OBJS)
	@mkdir -p $(BUILD)
	$(CXX) $(OBJS) $(LDFLAGS) -o $@

$(BUILD)/%.o: %.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -MMD -MP -c $< -o $@

# Shader compilation needs the Metal toolchain (full Xcode). If it is missing,
# say so and carry on — main.cpp compiles the .metal source at runtime instead.
shaders:
	@if xcrun -sdk macosx metal --version >/dev/null 2>&1; then \
		$(MAKE) --no-print-directory $(LIBRARY); \
	else \
		echo "note: Metal toolchain not installed — skipping precompiled shaders."; \
		echo "      install: xcodebuild -downloadComponent MetalToolchain"; \
	fi

$(LIBRARY): $(AIRS)
	@mkdir -p $(BUILD)
	$(METALLIB) $(AIRS) -o $@

$(BUILD)/%.air: %.metal
	@mkdir -p $(BUILD)
	$(METAL) -c $< -o $@

run: all
	@./$(BIN)

clean:
	rm -rf $(BUILD)

help:
	@echo "make          build the binary and the shader library"
	@echo "make run      build, then run it"
	@echo "make shaders  compile *.metal into $(LIBRARY)"
	@echo "make clean    remove $(BUILD)/"

-include $(DEPS)
EOF
sed -i '' "s/__PROJECT_NAME__/$PROJECT_NAME/g" "$TARGET_DIR/Makefile"

# ------------------------------------------------------ IDE / clangd flags ---
# One argument per line. The sysroot is baked in from this machine's SDK so
# Zed's clangd resolves the system headers instead of underlining them.

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
*.air
*.metallib
*.o
*.d
.DS_Store
.cache/
compile_commands.json

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
├── Makefile
└── compile_flags.txt       include paths for clangd (Zed, VS Code, nvim)
\`\`\`

## Build

\`\`\`sh
make run
\`\`\`

\`make\` builds \`build/$PROJECT_NAME\` and, when the Metal shader compiler is
installed, \`build/default.metallib\`. If it isn't, that step is skipped with a
note and the C++ side still builds — load the library with
\`device->newLibrary(NS::URL::fileURLWithPath(...), &error)\` once you have one.

## Requirements

| Tool | Install |
| --- | --- |
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
- \`compile_flags.txt\` points clangd at \`metal-cpp/\` and this machine's SDK.
  If Zed still shows red lines, restart it after \`metal-cpp/\` is populated.
EOF

# ============================================================== next steps ===

banner "Next steps"
printf '  cd %s\n' "$TARGET_DIR"
if [ ! -f "$TARGET_DIR/metal-cpp/Metal/Metal.hpp" ]; then
    printf '  %s# download metal-cpp first — see metal-cpp/PUT_METAL_CPP_HERE.md%s\n' "$C_YELLOW" "$C_RESET"
fi
printf '  make run\n'
