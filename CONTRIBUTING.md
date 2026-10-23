# Contributing to MBGA

The changes most likely to be accepted are:

- Bug fixes
- Memory, CPU and power improvements, with numbers from [`bench/`](bench/README.md)
- Arc behavior MBGA is missing or gets wrong
- Importing from more browsers, or more from the ones already supported
- Documentation improvements

New features and visible UI changes need agreement on the design first.
Open an issue that describes the problem, why it belongs in MBGA and how
you'd approach it, and wait for a reply before writing the code. The
[Not yet built](README.md#not-yet-built) list is a good place to look for
work that's already wanted.

> [!NOTE]
> Pull requests that skip this step, or that grow memory use without a good
> reason, will likely be closed.

## Development

You need macOS 15 or later on Apple silicon, Xcode, Rust (`rustup`), CMake
and Homebrew. From the repository root:

```sh
brew bundle               # formatters and linters the checks use
scripts/build.sh          # downloads CEF (~130 MB) on first run, then builds
scripts/build.sh --run    # build and launch
```

The app is written to `build/cmake/out/MBGA.app`. Rust's version is pinned
in `rust-toolchain.toml`, so `rustup` picks it up on its own.

If you work in several worktrees, install [kache](https://docs.rs/crate/kache)
with `cargo +stable install kache --locked` (it needs a newer Rust than the
pinned one). The build uses it when it's on your path, so a new worktree
restores the Rust core from the cache instead of compiling it again: about 6
seconds instead of a minute. You don't need `kache init`.

A development build stores its data in `~/Library/Application Support/MBGA`,
the same folder as an installed copy, and shares its preferences. If you
also use MBGA day to day, give test runs a folder of their own so they don't
touch your real tabs:

```sh
MBGA_DATA_DIR="$(mktemp -d)" build/cmake/out/MBGA.app/Contents/MacOS/MBGA
```

Builds from source never update themselves, so a release can't replace the
copy you're working on. They are also ad-hoc signed and use Chromium's mock
keychain, which avoids a keychain prompt on every rebuild; the key that seals
saved passwords then sits in `passwords.key` in the data folder.

### Layout

- `core/`: Rust. Spaces, profiles, tabs, favorites, folders, persistence,
  tab sleep policy, omnibox, ad blocking, imports and passwords. Exposed to
  Swift through UniFFI.
- `media/`: Rust built to WebAssembly. Converts H.264 and AAC, which the
  engine can't decode, to VP9 and FLAC inside pages; the page script and
  worker that run it are in `shell/resources/media/`.
- `shell/engine/`: Objective-C++ bridge to CEF (`MBEngine`).
- `shell/helper/`: entry point of Chromium's subprocesses.
- `shell/app/`: the AppKit UI.
- `bench/`: memory, CPU, power and speed benchmarks against other browsers.
- `scripts/`: build, check, release and measurement scripts.

The core owns the data. The shell renders snapshots of it and forwards
engine events back, and keeps no browser state of its own. Changes that
need new state belong in `core/`, with tests.

### Checks

Every change has to pass `scripts/check.sh`. `scripts/build.sh` turns on a
pre-commit hook that runs it, and CI runs it on every push and pull request.
`scripts/check.sh --fix` formats everything and applies the linters' safe
fixes. To run only the core's tests:

```sh
cargo test --manifest-path core/Cargo.toml
```

| Code                                             | Formatter                                      | Linter                                                                           |
| ------------------------------------------------ | ---------------------------------------------- | -------------------------------------------------------------------------------- |
| Rust (`core/`)                                   | rustfmt (`core/rustfmt.toml`)                  | clippy, pedantic, warnings are errors (`core/Cargo.toml`)                        |
| Rust (`media/`)                                  | rustfmt (`media/rustfmt.toml`)                 | clippy, pedantic, warnings are errors, also for WebAssembly (`media/Cargo.toml`) |
| Swift (`shell/`, `bench/`)                       | SwiftFormat (`.swiftformat`)                   | SwiftLint `--strict` (`.swiftlint.yml`)                                          |
| Objective-C++ (`shell/engine/`, `shell/helper/`) | clang-format, Chromium style (`.clang-format`) |                                                                                  |
| Python (`bench/`)                                | ruff (`ruff.toml`)                             | ruff                                                                             |
| Shell (`scripts/`, `media/tests/fixtures/`)      | shfmt (`.editorconfig`)                        | ShellCheck (`.shellcheckrc`)                                                     |

Beyond style, the checks hold the architecture in place:

- Only `shell/engine/` and `shell/helper/` include CEF; the rest of the shell
  goes through `MBEngine`.
- The shell is AppKit: SwiftUI isn't imported.
- `unsafe` Rust is confined to `core/src/crypto.rs` and `media/src/ffi.rs`
  (the WebAssembly module's exports), and each block says why it's sound.
- The core doesn't print, panic on `unwrap()` or leave `todo!()` behind.
- Files, types and functions have size and complexity limits (SwiftLint's
  `file_length`, `type_body_length`, `function_body_length` and
  `cyclomatic_complexity`, clippy's `too_many_lines` and
  `cognitive_complexity`, ruff's pylint rules). Past the limit, split the
  code by what it does.
- The code has no comments: names and structure say what it does, and the
  commit message says why. `scripts/comments.py` fails on any comment and
  `--fix` removes them. It keeps only directives tools read: shebangs,
  `swiftlint:`, `noqa`, `shellcheck`, `// SAFETY:` on `unsafe` blocks (clippy
  requires them) and the like.

Swift that was over a size limit before the limit existed is listed in
`.swiftlint-baseline.json`. `scripts/swiftlint-ratchet.py` lets that code
shrink but not grow. Regenerate the list with
`swiftlint lint --write-baseline .swiftlint-baseline.json` only when a rule
changes, never to let new code in.

Commits that only reformat go in `.git-blame-ignore-revs`, so `git blame`
skips them (`scripts/build.sh` sets that up too).

### Measuring memory

If your change could affect memory, CPU or power, measure it.
`scripts/measure-memory.sh` prints each process's physical footprint while
MBGA is open, and [`bench/`](bench/README.md) compares whole browsers on a
fixed set of sites. Put the before and after numbers in the pull request.

## Pull requests

### Keep it focused

- Base the branch on `dev` and open the pull request against `dev`.
- One feature or fix per pull request, and one commit per feature or fix.
- Explain the problem and why the change fixes it.
- Check whether MBGA already does it.
- For UI changes, include before-and-after screenshots or a short video.
- For logic changes, say what you tested and how a reviewer can check it.

### Keep it brief

Write the description in your own words. Long, generated descriptions may be
ignored; if the change can't be explained in a few sentences, it's probably
too big for one pull request.

### Write commits like the history

The subject line says what changed from the user's point of view, in plain
English, for example:

- `Give MBGA its own icon, and let it open web pages from Finder`
- `Choose per tab whether it sleeps or stays awake for good`
- `Let the build and release scripts run where the locale isn't UTF-8`

The body explains why and how.

## Branches and releases

- `dev` is where work lands. Open pull requests against `dev`.
- `main` always matches the latest release.

To release, run the **Release** workflow (Actions ▸ Release ▸ Run workflow)
from `dev` and choose which part of the version to raise. It:

1. sets `MBGA_VERSION` in `CMakeLists.txt` to the version after the latest
   tag (`scripts/bump-version.sh`) and commits it to `dev`,
2. builds, signs and notarizes the app, then publishes the GitHub release
   with its tag, which every installed copy picks up (`scripts/release.sh`),
3. merges the release into `main`.

For a hotfix, branch from `main`, merge the fix into `main` and run the
workflow from `main`. The release is then merged back into `dev`. If that
merge conflicts, the workflow fails after publishing; merge the tag into
`dev` by hand.

If a release fails before publishing, run the workflow again: it finds the
version raised already and doesn't raise it twice.

The workflow needs these repository secrets:

| Secret | What it holds |
| --- | --- |
| `MBGA_UPDATE_KEY` | The update signing key (`security find-generic-password -s "MBGA update signing key" -a mbga -w`). Copies only accept updates signed with it. |
| `APPLE_DEVELOPMENT_P12`, `APPLE_DEVELOPMENT_P12_PASSWORD` | The Apple Development certificate and its private key, exported from Keychain Access as a .p12 and base64-encoded, with its password. |
| `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | An App Store Connect API key with the Admin role, which lets Xcode sign with the cloud-managed Developer ID and notarize. |

`scripts/release.sh` also runs on a Mac signed into Xcode with the team's
account, using the keys in your keychain:

- Generate a release key with `swift scripts/update-signing.swift generate`,
  store the private half as "MBGA update signing key" in your keychain and
  put the public half in `MBGA_UPDATE_PUBLIC_KEY`.
- `scripts/build.sh --release` builds a copy that updates itself. To try an
  update without publishing one, point a build at a local feed:
  `MBGA_UPDATE_FEED=file:///path/to/update.json`.
- The app is signed with an Apple Development identity and the hardened
  runtime, then Xcode signs it with the team's cloud-managed Developer ID and
  has Apple notarize it (`MBGA_SIGN_IDENTITY` and `MBGA_TEAM` choose another
  team).
- Configure with `-DMBGA_MOCK_KEYCHAIN=OFF` for a release that encrypts
  cookies with the real keychain.

## Issues

For a bug, say what you did, what you expected and what happened instead,
with your macOS version and MBGA version (MBGA ▸ About MBGA). For a memory
problem, include the output of `scripts/measure-memory.sh`.
