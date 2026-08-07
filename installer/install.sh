#!/usr/bin/env bash
# Install redub to a per-user prefix and ensure ~/.local/bin is on PATH.
set -euo pipefail

APP=redub
PREFIX="${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/$APP}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
SKIP_PATH="${SKIP_PATH:-0}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
candidates=(
  "$here/$APP"
)
# Release-named assets next to the installer (portable package or cwd).
shopt -s nullglob
for f in "$here"/redub-*-linux-* "$here"/redub-*-osx-*; do
  case "$f" in
    *.zip|*.tar.gz|*.ps1|*.sh|*.nu) continue ;;
  esac
  candidates+=("$f")
done
shopt -u nullglob
candidates+=(
  "$(dirname "$here")/$APP"
  "$(pwd)/$APP"
)

src=""
for c in "${candidates[@]}"; do
  if [[ -f "$c" ]]; then
    case "$(basename "$c")" in
      install.sh|install.ps1|install.nu|redub-install.*) continue ;;
    esac
    src="$c"
    break
  fi
done
if [[ -z "$src" ]]; then
  echo "error: $APP binary not found next to this script, repo root, or cwd" >&2
  exit 1
fi

mkdir -p "$PREFIX" "$BIN_DIR"
install -m 755 "$src" "$PREFIX/$APP"
if [[ -f "$(dirname "$src")/LICENSE" ]]; then
  cp "$(dirname "$src")/LICENSE" "$PREFIX/LICENSE"
fi
ln -sfn "$PREFIX/$APP" "$BIN_DIR/$APP"

cat >"$PREFIX/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
PREFIX="$PREFIX"
BIN_DIR="$BIN_DIR"
APP="$APP"
rm -f "\$BIN_DIR/\$APP"
rm -rf "\$PREFIX"
echo "Removed \$PREFIX and symlink \$BIN_DIR/\$APP"
echo "Open a new shell if the command is still hashed."
EOF
chmod +x "$PREFIX/uninstall.sh"

echo "Installed: $PREFIX/$APP"
echo "Symlink:   $BIN_DIR/$APP"
"$PREFIX/$APP" --version || true

if [[ "$SKIP_PATH" != "1" ]]; then
  case ":${PATH:}:" in
    *":$BIN_DIR:"*) echo "PATH already contains: $BIN_DIR" ;;
    *)
      echo ""
      echo "Add $BIN_DIR to PATH for this shell:"
      echo "  bash/zsh:  export PATH=\"$BIN_DIR:\$PATH\""
      echo "  fish:      fish_add_path $BIN_DIR"
      echo "  nushell:   \$env.PATH = (\$env.PATH | prepend '$BIN_DIR')"
      echo "  pwsh:      \$env:Path = '$BIN_DIR;' + \$env:Path"
      ;;
  esac
fi

echo ""
echo "Uninstall: $PREFIX/uninstall.sh"
