# project-scaffolding

`main.sh` is a menu: it asks which project template you want and the few things
it can't guess (name, where to put it, git or not), then hands off to the
matching script in `scaffolds/`, which writes the actual files.

```sh
./main.sh                                        # interactive menu
./main.sh metal-cpp                              # skip the menu
./main.sh llama-cpp --name chat --dir ~/code --yes
./main.sh --list
```

| Option | |
| --- | --- |
| `--name NAME` | project name, also the directory name |
| `--dir DIR` | parent directory (default: cwd) |
| `-y, --yes` | accept every default, never prompt |
| `-l, --list` | list scaffolds |

## Layout

```
project-scaffolding/
├── main.sh              menu + the questions common to every scaffold
├── lib/common.sh        logging, prompts, dependency checks
└── scaffolds/
    ├── llama-cpp.sh     one script per template
    └── metal-cpp.sh
```

## Scaffolds

### `metal-cpp` — GPU programming with Metal on Apple silicon

Generates a project that builds and runs as-is — plumbing only, no example
code to delete:

```
my_metal_project/
├── metal-cpp/              Apple's C++ bindings, downloaded and extracted for you
├── main.cpp                autorelease pool + device, and a place to type
├── mtl_implementation.cpp  the single TU that emits metal-cpp's symbols
├── default.metal           empty; CMake globs *.metal into one metallib
├── CMakeLists.txt          build, shaders, and a `run` target
├── compile_flags.txt       clangd fallback for before the first configure
├── .gitignore
└── README.md
```

```sh
cmake -S . -B build
cmake --build build --target run
```

Configuring symlinks `build/compile_commands.json` into the project root, which
is what clangd (Zed, VS Code, nvim) actually reads — no hand-maintained flags to
drift. `compile_flags.txt` is kept only as the fallback for before you've
configured; clangd prefers the compilation database when both exist.

It offers to download metal-cpp from Apple; decline (or lose the network) and
you get a placeholder folder with the exact commands to do it by hand.

The shader compiler (`xcrun metal`) ships with full Xcode, not the command line
tools, so it's often missing. CMake detects that at configure time and skips the
metallib with a note instead of failing, so the C++ side still builds.

For GPU frame capture and the shader debugger, `cmake -S . -B build-xcode -G
Xcode` generates an Xcode project (needs full Xcode selected).

### `llama-cpp` — local LLM inference, linked as a library

Generates a C++ project that builds against llama.cpp from source:

```
my_llama_project/
├── vendor/llama.cpp/     pinned to a release tag, plain source checkout
├── src/main.cpp          backend, model and context lifecycle — nothing else
├── models/               GGUF files (gitignored)
├── scripts/fetch-model.sh
├── CMakeLists.txt        your target only
├── CMakePresets.json     generator, build type, llama.cpp's options
├── compile_flags.txt
├── .gitignore
└── README.md
```

```sh
cmake --preset default     # Ninja + Release + Metal
cmake --build build
./build/<name> models/<model>.gguf
```

llama.cpp is pinned to a specific release tag rather than tracking a branch,
because its C API renames and deprecates functions regularly — `src/main.cpp` is
written against the tag it ships with. It is fetched with a shallow `git clone`
and left at that; the generated README lists the ways to bring it under version
control if you want to.

Its build options live in `CMakePresets.json`, which keeps `CMakeLists.txt`
about your code. Two are load-bearing: `BUILD_SHARED_LIBS=OFF`, because
llama.cpp defaults to shared libraries and leaves dylibs to find at runtime for
no benefit, and `GGML_METAL_EMBED_LIBRARY=ON`, which bakes ggml's Metal shader
source into the binary and compiles it at runtime — so unlike the metal-cpp
scaffold, this one needs no Xcode Metal toolchain.

Ninja is the default generator here rather than make: llama.cpp is a few hundred
translation units, and make builds one at a time unless told otherwise. A `make`
preset is included for machines without ninja.

## Dependencies

Scaffolds check what they need and **never install anything** — a missing tool
is reported with the command that would fix it, and generation continues.

## Version control

Nothing here runs `git init`, `git add`, or `git commit`. Scaffolds write a
`.gitignore` and stop — whether the result becomes a repository is your call.
The one place git is used at all is fetching third-party source at a pinned tag
(`llama-cpp`), which touches nothing outside the new project's `vendor/`.

## Adding a scaffold

Drop a script in `scaffolds/`. It's discovered automatically from three header
comments — no edits to `main.sh`:

```sh
# scaffold-name: Rust CLI
# scaffold-description: One line, shown in the menu.
# scaffold-default-name: my_cli
```

`main.sh` runs it with these exported:

| Variable | |
| --- | --- |
| `SCAFFOLD_PROJECT_NAME` | validated project name |
| `SCAFFOLD_TARGET_DIR` | absolute path to the (created) project directory |
| `SCAFFOLD_LIB_DIR` | source `$SCAFFOLD_LIB_DIR/common.sh` from here |
| `SCAFFOLD_ASSUME_YES` | `1` when `--yes` was passed; prompts return defaults |

From `common.sh`: `log_info/ok/warn/err/add`, `banner`, `die`, `ask`,
`ask_yes_no`, `have_cmd`, `check_dep` + `dep_report`, and `write_file <path>`
(reads content from stdin, creates parent dirs, logs the relative path).

Everything targets bash 3.2, the system bash on macOS — no associative arrays,
no `mapfile`, no `${var,,}`.
