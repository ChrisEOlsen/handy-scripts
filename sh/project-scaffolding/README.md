# project-scaffolding

`main.sh` is a menu: it asks which project template you want and the few things
it can't guess (name, where to put it, git or not), then hands off to the
matching script in `scaffolds/`, which writes the actual files.

```sh
./main.sh                                        # interactive menu
./main.sh metal-cpp                              # skip the menu
./main.sh metal-cpp --name particles --dir ~/code --yes
./main.sh --list
```

| Option | |
| --- | --- |
| `--name NAME` | project name, also the directory name |
| `--dir DIR` | parent directory (default: cwd) |
| `--no-git` | skip `git init` |
| `-y, --yes` | accept every default, never prompt |
| `-l, --list` | list scaffolds |

## Layout

```
project-scaffolding/
├── main.sh              menu + the questions common to every scaffold
├── lib/common.sh        logging, prompts, dependency checks
└── scaffolds/
    └── metal-cpp.sh     one script per template
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

## Dependencies

Scaffolds check what they need and **never install anything** — a missing tool
is reported with the command that would fix it, and generation continues.

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
| `SCAFFOLD_GIT_INIT` | `1` if `main.sh` will `git init` afterwards |
| `SCAFFOLD_LIB_DIR` | source `$SCAFFOLD_LIB_DIR/common.sh` from here |
| `SCAFFOLD_ASSUME_YES` | `1` when `--yes` was passed; prompts return defaults |

From `common.sh`: `log_info/ok/warn/err/add`, `banner`, `die`, `ask`,
`ask_yes_no`, `have_cmd`, `check_dep` + `dep_report`, and `write_file <path>`
(reads content from stdin, creates parent dirs, logs the relative path).

Everything targets bash 3.2, the system bash on macOS — no associative arrays,
no `mapfile`, no `${var,,}`.
