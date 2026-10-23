#!/usr/bin/env bash
# Checks that the code is formatted and passes every linter and the Rust
# crates' tests. CI and the pre-commit hook run it; a change that fails it
# doesn't go in. Pass --fix to format everything and apply the linters' safe
# fixes first, then check what's left.
#
# Tools: `brew bundle` installs them from the Brewfile; Rust comes from
# rust-toolchain.toml and ruff runs through uv at the version pinned below.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUFF_VERSION="0.17.1"
FIX=0
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    *)
      echo "usage: $0 [--fix]" >&2
      exit 2
      ;;
  esac
done

missing=()
for tool in cargo swiftformat swiftlint clang-format shellcheck shfmt uvx; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
  echo "Missing: ${missing[*]}. Run \`brew bundle\` (and install rustup and uv)." >&2
  exit 1
fi

# An older SwiftFormat fails on rules it doesn't know before it gets to
# .swiftformat's own --minversion, with a less helpful message.
need="$(sed -n 's/^--minversion //p' .swiftformat)"
have="$(swiftformat --version)"
if [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
  echo "SwiftFormat $have is older than $need, which .swiftformat needs: brew upgrade swiftformat" >&2
  exit 1
fi

FAILED=()
step() {
  local name="$1"
  shift
  echo "==> $name"
  if ! "$@"; then
    FAILED+=("$name")
  fi
}

ruff() { uvx --quiet "ruff@$RUFF_VERSION" "$@"; }
OBJC=(shell/engine/MBEngine.h shell/engine/MBEngine.mm shell/helper/helper_main.mm)
SHELL_SCRIPTS=(scripts/*.sh .githooks/* media/tests/fixtures/make.sh)

if [[ "$FIX" == 1 ]]; then
  cargo fmt --manifest-path core/Cargo.toml
  cargo clippy --manifest-path core/Cargo.toml --all-targets --fix --allow-dirty --allow-staged --quiet
  cargo fmt --manifest-path media/Cargo.toml
  cargo clippy --manifest-path media/Cargo.toml --all-targets --fix --allow-dirty --allow-staged --quiet
  swiftformat --quiet .
  swiftlint lint --fix --quiet
  clang-format -i "${OBJC[@]}"
  ruff check --fix --quiet .
  ruff format --quiet .
  shfmt -w "${SHELL_SCRIPTS[@]}"
fi

step "rustfmt" cargo fmt --manifest-path core/Cargo.toml --check
step "clippy" cargo clippy --manifest-path core/Cargo.toml --all-targets --quiet -- -D warnings
step "cargo test" cargo test --manifest-path core/Cargo.toml --quiet
step "rustfmt (media)" cargo fmt --manifest-path media/Cargo.toml --check
step "clippy (media)" cargo clippy --manifest-path media/Cargo.toml --all-targets --quiet -- -D warnings
# What ships is the WebAssembly build, whose code paths differ (src/ffi.rs).
step "clippy (media, wasm)" cargo clippy --manifest-path media/Cargo.toml --target wasm32-unknown-unknown --quiet -- -D warnings
step "cargo test (media)" cargo test --manifest-path media/Cargo.toml --quiet
step "swiftformat" swiftformat --lint --quiet .
step "swiftlint" scripts/swiftlint-ratchet.py
step "clang-format" clang-format --dry-run --Werror "${OBJC[@]}"
step "ruff format" ruff format --check --quiet .
step "ruff check" ruff check --quiet --output-format concise .
step "shfmt" shfmt -d "${SHELL_SCRIPTS[@]}"
step "shellcheck" shellcheck "${SHELL_SCRIPTS[@]}"

if ((${#FAILED[@]})); then
  echo "Failed: ${FAILED[*]}" >&2
  [[ "$FIX" == 1 ]] || echo "scripts/check.sh --fix repairs formatting; the rest needs fixing by hand." >&2
  exit 1
fi
echo "All checks passed."
