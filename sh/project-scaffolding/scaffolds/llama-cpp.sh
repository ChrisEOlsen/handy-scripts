#!/usr/bin/env bash
# scaffold-name: llama.cpp (local LLM inference)
# scaffold-description: C++ app linking libllama — pinned source checkout, Ninja presets, Metal on by default, and a GGUF fetch script.
# scaffold-default-name: my_llama_project
#
# Generates:
#   <project>/
#   ├── vendor/llama.cpp/     source checkout pinned to a release tag
#   ├── src/main.cpp          your code — backend/model/context lifecycle only
#   ├── models/               GGUF files live here (gitignored)
#   ├── scripts/fetch-model.sh
#   ├── CMakeLists.txt        your target; llama.cpp comes in via add_subdirectory
#   ├── CMakePresets.json     generator + build type + the llama.cpp knobs
#   ├── compile_flags.txt     clangd/Zed fallback until build/ has been configured
#   ├── .gitignore
#   └── README.md
#
# Invoked by main.sh, which exports SCAFFOLD_PROJECT_NAME, SCAFFOLD_TARGET_DIR,
# SCAFFOLD_LIB_DIR and SCAFFOLD_ASSUME_YES.
#
# git is used to fetch llama.cpp at a pinned tag and for nothing else — no repo
# is created here, and nothing outside <project>/vendor/ is touched.

set -euo pipefail

# shellcheck source=../lib/common.sh
. "${SCAFFOLD_LIB_DIR:?must be run via main.sh}/common.sh"

PROJECT_NAME="${SCAFFOLD_PROJECT_NAME:?}"
TARGET_DIR="${SCAFFOLD_TARGET_DIR:?}"

LLAMA_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
# Release tags look like b10488. Pinning one keeps the C API stable — llama.cpp
# renames and deprecates functions regularly, and main.cpp below is written
# against exactly this tag.
LLAMA_TAG_DEFAULT="${LLAMA_CPP_TAG:-b10488}"
LLAMA_SUBDIR="vendor/llama.cpp"

# ======================================================= dependency checks ===
# Nothing is installed here — missing tools are reported with the command that
# would fix them.

banner "Checking dependencies"

check_dep "git (to fetch the llama.cpp source)" \
    "command -v git" \
    "xcode-select --install"

check_dep "clang++ (C++ compiler)" \
    "command -v clang++" \
    "xcode-select --install"

check_dep "cmake" \
    "command -v cmake" \
    "brew install cmake"

# CMakePresets.json needs 3.21; llama.cpp itself only needs 3.14.
if have_cmd cmake; then
    check_dep "cmake >= 3.21 (for CMakePresets.json)" \
        "cmake --version | head -1 | awk '{print \$3}' | awk -F. '{exit !(\$1>3 || (\$1==3 && \$2>=21))}'" \
        "brew upgrade cmake"
fi

# The reason ninja is worth having here and not in the metal-cpp scaffold:
# llama.cpp is several hundred translation units, and make runs one job at a
# time unless told otherwise.
check_dep "ninja (much faster than make on a build this size)" \
    "command -v ninja" \
    "brew install ninja" "optional"
if [ "$DEP_OK" -eq 0 ]; then
    log_hint "Without it, use the 'make' preset instead of 'default'."
fi

check_dep "Xcode command line tools" \
    "xcode-select -p" \
    "xcode-select --install"

# llama.cpp's own CMake warns about this one, and it matters whenever you bump
# the pinned tag and rebuild the whole thing.
check_dep "ccache (caches llama.cpp rebuilds)" \
    "command -v ccache" \
    "brew install ccache   # or set GGML_CCACHE=OFF to silence the warning" "optional"

check_dep "curl (to download models)" \
    "command -v curl" \
    "brew install curl" "optional"

check_dep "hf (Hugging Face CLI, nicer model downloads)" \
    "command -v hf || command -v huggingface-cli" \
    "pip install -U huggingface_hub   # or: brew install huggingface-cli" "optional"
if [ "$DEP_OK" -eq 0 ]; then
    log_hint "scripts/fetch-model.sh falls back to curl, so this is only a convenience."
fi

check_dep "clangd (IDE completion for Zed)" \
    "command -v clangd" \
    "brew install llvm   # then add \$(brew --prefix llvm)/bin to PATH" "optional"

if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
    # Worth stating plainly: unlike the metal-cpp scaffold, this one does NOT
    # need the Metal shader compiler. GGML_METAL_EMBED_LIBRARY (on by default)
    # embeds ggml's .metal source into the binary and compiles it at runtime,
    # so the build works with only the command line tools installed.
    log_ok "Apple silicon — Metal backend on, no Xcode Metal toolchain required"
else
    log_warn "Not Apple silicon — the presets enable Metal, which will not apply here."
    log_hint "Drop GGML_METAL from CMakePresets.json; llama.cpp falls back to CPU."
fi

dep_report

# =============================================================== questions ===

banner "llama.cpp project options"

llama_tag="$LLAMA_TAG_DEFAULT"
clone_llama=0

if have_cmd git; then
    log_info "llama.cpp is ~200 MB shallow-cloned."
    if ask_yes_no "Fetch llama.cpp into $LLAMA_SUBDIR now?" "y"; then
        clone_llama=1
        llama_tag="$(ask "Release tag to pin" "$LLAMA_TAG_DEFAULT")"
    fi
else
    log_warn "git unavailable — $LLAMA_SUBDIR will be a placeholder."
fi

# =============================================================== generation ==

banner "Creating $PROJECT_NAME"

mkdir -p "$TARGET_DIR"
log_info "$TARGET_DIR"

# ------------------------------------------------------------- llama.cpp ----
#
# A shallow clone at a fixed tag, and nothing more. The checkout keeps its own
# .git so you can adopt it as a submodule, move the pin, or delete .git and
# vendor the sources outright — see the generated README.

fetch_llama_cpp() {
    _dest="$TARGET_DIR/$LLAMA_SUBDIR"

    if [ -e "$_dest" ]; then
        log_warn "$LLAMA_SUBDIR already exists — leaving it alone."
        return 0
    fi

    mkdir -p "$(dirname "$_dest")"

    log_info "Cloning llama.cpp at $llama_tag (shallow)"
    if ! git -c advice.detachedHead=false \
            clone --depth 1 --branch "$llama_tag" "$LLAMA_REPO" "$_dest"; then
        rm -rf "$_dest"
        return 1
    fi

    return 0
}

llama_ready=0
if [ "$clone_llama" -eq 1 ]; then
    if fetch_llama_cpp && [ -f "$TARGET_DIR/$LLAMA_SUBDIR/include/llama.h" ]; then
        llama_ready=1
        log_ok "$LLAMA_SUBDIR ready ($(git -C "$TARGET_DIR/$LLAMA_SUBDIR" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    else
        log_warn "Clone failed — falling back to a placeholder."
    fi
fi

if [ "$llama_ready" -eq 0 ] && [ ! -f "$TARGET_DIR/$LLAMA_SUBDIR/include/llama.h" ]; then
    mkdir -p "$TARGET_DIR/$LLAMA_SUBDIR"
    write_file "$TARGET_DIR/$LLAMA_SUBDIR/PUT_LLAMA_CPP_HERE.md" <<EOF
# llama.cpp goes here

This folder is a placeholder — CMake will refuse to configure until it holds a
real checkout with \`include/llama.h\` in it.

    rm -rf $LLAMA_SUBDIR
    git clone --depth 1 --branch $llama_tag $LLAMA_REPO $LLAMA_SUBDIR

\`src/main.cpp\` is written against tag \`$llama_tag\`. Newer tags are fine, but
llama.cpp does rename and deprecate C API functions, so check the build output
if you move the pin.
EOF
fi

# --------------------------------------------------------------- sources ----

write_file "$TARGET_DIR/src/main.cpp" <<'EOF'
// main.cpp

#include "llama.h"

#include <cstdio>

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.gguf>\n", argv[0]);
        return 1;
    }
    const char* model_path = argv[1];

    // Uncomment to silence the loader's log spam on stderr:
    // llama_log_set([](ggml_log_level, const char*, void*) {}, nullptr);

    llama_backend_init();

    // n_gpu_layers defaults to -1, which offloads every layer to the GPU.
    // Set it to 0 for CPU-only.
    llama_model_params model_params = llama_model_default_params();

    llama_model* model = llama_model_load_from_file(model_path, model_params);
    if (!model) {
        std::fprintf(stderr, "failed to load model: %s\n", model_path);
        llama_backend_free();
        return 1;
    }

    // n_ctx = 0 means "use the model's training context", which can be very
    // large and allocate a correspondingly large KV cache.
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 4096;

    llama_context* ctx = llama_init_from_model(model, ctx_params);
    if (!ctx) {
        std::fprintf(stderr, "failed to create context\n");
        llama_model_free(model);
        llama_backend_free();
        return 1;
    }

    const llama_vocab* vocab = llama_model_get_vocab(model);

    char desc[256];
    llama_model_desc(model, desc, sizeof(desc));

    std::printf("model   : %s\n", desc);
    std::printf("params  : %llu\n", (unsigned long long) llama_model_n_params(model));
    std::printf("size    : %.1f MiB\n", (double) llama_model_size(model) / (1024.0 * 1024.0));
    std::printf("n_ctx   : %u (trained on %d)\n", llama_n_ctx(ctx), llama_model_n_ctx_train(model));
    std::printf("n_embd  : %d\n", llama_model_n_embd(model));
    std::printf("n_layer : %d\n", llama_model_n_layer(model));
    std::printf("vocab   : %d tokens\n", llama_vocab_n_tokens(vocab));

    // Your code goes here.

    // Free in reverse order — the context holds a reference to the model.
    llama_free(ctx);
    llama_model_free(model);
    llama_backend_free();
    return 0;
}
EOF

# ------------------------------------------------------------ CMakeLists ----

write_file "$TARGET_DIR/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.21)
project(__PROJECT_NAME__ LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Feeds clangd (Zed, VS Code, nvim). Honoured by the Ninja and Makefile
# generators; the Xcode generator ignores it.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT EXISTS "${CMAKE_SOURCE_DIR}/vendor/llama.cpp/include/llama.h")
    message(FATAL_ERROR
        "llama.cpp is missing from vendor/llama.cpp — see "
        "vendor/llama.cpp/PUT_LLAMA_CPP_HERE.md for the one command that fetches it. "
        "If you made it a submodule: git submodule update --init --depth 1")
endif()

# llama.cpp's own build options are set in CMakePresets.json, not here, so this
# file stays about your code. Building it as a subproject already switches its
# tests, tools, examples and server off — LLAMA_STANDALONE is only ON when
# llama.cpp is the top-level project.
add_subdirectory(vendor/llama.cpp EXCLUDE_FROM_ALL)

add_executable(${PROJECT_NAME}
    src/main.cpp
)

target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra)

# The `llama` target carries its own include directories, so there is no
# target_include_directories call to keep in sync here.
target_link_libraries(${PROJECT_NAME} PRIVATE llama)

# llama.cpp's helper library — common_params, common_init_from_params,
# common_sampler, the chat templating. Everything under its examples/ and
# tools/ is written against this, so turn it on before copying code from there.
# It pulls in cpp-httplib and nlohmann/json, which is why it is off by default.
#
# Set LLAMA_BUILD_COMMON to ON in CMakePresets.json, then uncomment:
# target_link_libraries(${PROJECT_NAME} PRIVATE llama-common)

# Keep clangd happy without pointing it into build/: symlink the compilation
# database next to the sources. Harmless if it is already there.
if(CMAKE_EXPORT_COMPILE_COMMANDS AND NOT CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
    file(CREATE_LINK
        "${CMAKE_BINARY_DIR}/compile_commands.json"
        "${CMAKE_SOURCE_DIR}/compile_commands.json"
        SYMBOLIC
    )
endif()
EOF
sed -i '' "s/__PROJECT_NAME__/$PROJECT_NAME/g" "$TARGET_DIR/CMakeLists.txt"

# --------------------------------------------------------- CMakePresets -----

write_file "$TARGET_DIR/CMakePresets.json" <<'EOF'
{
    "version": 3,
    "cmakeMinimumRequired": { "major": 3, "minor": 21, "patch": 0 },
    "configurePresets": [
        {
            "name": "base",
            "hidden": true,
            "description": "llama.cpp build options. BUILD_SHARED_LIBS=OFF because llama.cpp defaults to shared libraries, leaving dylibs to locate at runtime for no benefit. GGML_METAL_EMBED_LIBRARY bakes ggml's Metal shader source into the binary and compiles it at runtime, so no Xcode Metal toolchain is needed. The LLAMA_BUILD_* flags are already off for a subproject; they are pinned so an update cannot turn them back on.",
            "binaryDir": "${sourceDir}/build",
            "cacheVariables": {
                "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
                "BUILD_SHARED_LIBS": "OFF",
                "GGML_METAL": "ON",
                "GGML_METAL_EMBED_LIBRARY": "ON",
                "LLAMA_BUILD_COMMON": "OFF",
                "LLAMA_BUILD_TESTS": "OFF",
                "LLAMA_BUILD_EXAMPLES": "OFF",
                "LLAMA_BUILD_TOOLS": "OFF",
                "LLAMA_BUILD_SERVER": "OFF"
            }
        },
        {
            "name": "default",
            "displayName": "Ninja, Release",
            "inherits": "base",
            "generator": "Ninja",
            "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
        },
        {
            "name": "debug",
            "displayName": "Ninja, Debug",
            "inherits": "base",
            "generator": "Ninja",
            "binaryDir": "${sourceDir}/build-debug",
            "cacheVariables": { "CMAKE_BUILD_TYPE": "Debug" }
        },
        {
            "name": "make",
            "displayName": "Unix Makefiles, Release (if ninja is not installed)",
            "inherits": "base",
            "generator": "Unix Makefiles",
            "binaryDir": "${sourceDir}/build-make",
            "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
        }
    ],
    "buildPresets": [
        { "name": "default", "configurePreset": "default" },
        { "name": "debug", "configurePreset": "debug" },
        { "name": "make", "configurePreset": "make", "jobs": 0 }
    ]
}
EOF

# ---------------------------------------------------------------- scripts ---

write_file "$TARGET_DIR/scripts/fetch-model.sh" <<'EOF'
#!/usr/bin/env bash
# fetch-model.sh <hf-repo> <file.gguf> — download a GGUF model into models/.
set -euo pipefail

REPO="${1:-}"
FILE="${2:-}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/models"

if [ -z "$REPO" ] || [ -z "$FILE" ]; then
    cat >&2 <<USAGE
usage: $(basename "$0") <hf-repo> <file.gguf>

example:
  $(basename "$0") ggml-org/gemma-3-1b-it-GGUF gemma-3-1b-it-Q4_K_M.gguf

Browse GGUF models: https://huggingface.co/models?library=gguf
The file list for a repo is under its "Files and versions" tab.
USAGE
    exit 1
fi

# The repo-relative path may have directories in it (tinyllamas/foo.gguf).
mkdir -p "$(dirname "$DEST/$FILE")"

if command -v hf >/dev/null 2>&1; then
    hf download "$REPO" "$FILE" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null 2>&1; then
    huggingface-cli download "$REPO" "$FILE" --local-dir "$DEST"
else
    echo "hf CLI not found (pip install -U huggingface_hub) — falling back to curl." >&2
    curl -fL --progress-bar \
        -o "$DEST/$FILE" \
        "https://huggingface.co/$REPO/resolve/main/$FILE?download=true"
fi

echo
echo "-> $DEST/$FILE"
EOF
chmod +x "$TARGET_DIR/scripts/fetch-model.sh"

# ----------------------------------------------------------------- models ---

mkdir -p "$TARGET_DIR/models"
write_file "$TARGET_DIR/models/.gitkeep" <<'EOF'
EOF

# --------------------------------------------------------- clangd fallback --

SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
{
    cat <<'EOF'
-xc++
-std=c++17
-Wall
-Wextra
-Ivendor/llama.cpp/include
-Ivendor/llama.cpp/ggml/include
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
.cache/
compile_commands.json
.DS_Store

# Models are large. Keep the directory, not its contents.
models/*
!models/.gitkeep
*.gguf

# vendor/llama.cpp is a third-party checkout with its own .git. If you put this
# project under version control, pick one: uncomment the line below to leave it
# out entirely, register it as a submodule, or delete its .git and commit the
# sources. See the README.
# vendor/
EOF

# ----------------------------------------------------------------- README ---

write_file "$TARGET_DIR/README.md" <<EOF
# $PROJECT_NAME

Local LLM inference with [llama.cpp]($LLAMA_REPO), linked as a library.

## Layout

\`\`\`
$PROJECT_NAME/
├── vendor/llama.cpp/     pinned to $llama_tag, built from source
├── src/main.cpp          your code — backend, model and context lifecycle
├── models/               GGUF files (gitignored)
├── scripts/fetch-model.sh
├── CMakeLists.txt        your target
├── CMakePresets.json     generator, build type, llama.cpp options
└── compile_flags.txt     clangd fallback until build/ has been configured
\`\`\`

## Build

\`\`\`sh
cmake --preset default     # Ninja + Release + Metal
cmake --build build
\`\`\`

The first build compiles llama.cpp from source — under a minute with ninja on
Apple silicon, considerably longer with the \`make\` preset. After that only
your own files rebuild.

Each preset has its own build directory, so they never clobber each other:
\`default\` → \`build/\`, \`debug\` → \`build-debug/\`, \`make\` →
\`build-make/\` (use that one if ninja is not installed). \`cmake --build
--preset <name>\` builds into the right one without you naming the directory.

## Run

\`\`\`sh
./scripts/fetch-model.sh ggml-org/gemma-3-1b-it-GGUF gemma-3-1b-it-Q4_K_M.gguf
./build/$PROJECT_NAME models/gemma-3-1b-it-Q4_K_M.gguf
\`\`\`

## Updating llama.cpp

\`src/main.cpp\` is written against tag \`$llama_tag\`. The C API changes often
enough that moving the pin is a deliberate act, not a \`git pull\`:

\`\`\`sh
git -C vendor/llama.cpp fetch --depth 1 origin refs/tags/<newer-tag>
git -C vendor/llama.cpp checkout FETCH_HEAD
\`\`\`

## Version control

This project is not a git repository — the scaffold only wrote a \`.gitignore\`.
\`vendor/llama.cpp\` is a plain checkout that kept its own \`.git\`, so if you
do start a repo here, decide what to do with it. Any of these is fine:

\`\`\`sh
# 1. keep it out of version control
echo 'vendor/' >> .gitignore

# 2. track it as a submodule, recording the exact pinned commit
git init && git submodule add $LLAMA_REPO vendor/llama.cpp

# 3. vendor the sources outright, no nested repo
rm -rf vendor/llama.cpp/.git
\`\`\`

Option 2 is the one that survives a fresh clone elsewhere, via
\`git submodule update --init --depth 1\`. Without it, nothing records which
llama.cpp commit this project was built against except the note above.

## Requirements

| Tool | Install |
| --- | --- |
| CMake >= 3.21 | \`brew install cmake\` |
| Ninja | \`brew install ninja\` |
| Command line tools | \`xcode-select --install\` |
| Hugging Face CLI (optional) | \`pip install -U huggingface_hub\` |

Full Xcode is **not** required. \`GGML_METAL_EMBED_LIBRARY\` bakes ggml's Metal
shader source into the binary and compiles it at runtime, so the Metal backend
builds with only the command line tools installed.

## Notes

- llama.cpp's build options live in \`CMakePresets.json\`, not \`CMakeLists.txt\`.
  Its tests, tools, examples and server are already off when it is built as a
  subproject; the presets pin them so an update cannot turn them back on.
- \`BUILD_SHARED_LIBS=OFF\` is deliberate. llama.cpp defaults to shared
  libraries, which leaves dylibs to locate at runtime for no benefit here.
- Anything you copy out of llama.cpp's \`examples/\` or \`tools/\` needs the
  \`llama-common\` library (note the name — it is not \`common\`). Set
  \`LLAMA_BUILD_COMMON\` to \`ON\` in the presets and uncomment the
  \`target_link_libraries\` line in \`CMakeLists.txt\`.
- Free order matters: \`llama_free(ctx)\` before \`llama_model_free(model)\`.
- Configuring symlinks \`build/compile_commands.json\` into the project root,
  which is what clangd actually uses. \`compile_flags.txt\` is only the fallback
  for before you have configured — clangd prefers the compilation database when
  both are present.
EOF

# ============================================================== next steps ===

banner "Next steps"
printf '  cd %s\n' "$TARGET_DIR"
if [ ! -f "$TARGET_DIR/$LLAMA_SUBDIR/include/llama.h" ]; then
    printf '  %s# fetch llama.cpp first — see %s/PUT_LLAMA_CPP_HERE.md%s\n' \
        "$C_YELLOW" "$LLAMA_SUBDIR" "$C_RESET"
fi
printf '  cmake --preset default\n'
printf '  cmake --build build\n'
printf '  ./scripts/fetch-model.sh <hf-repo> <file.gguf>\n'
