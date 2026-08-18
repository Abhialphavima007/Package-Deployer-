#!/usr/bin/env bash
# Package Deployer Studio - companion installer for macOS and Linux
#
#   ./install-mac.sh              install
#   ./install-mac.sh --uninstall  remove
#
# Installs to ~/.local/share/package-deployer-studio and puts a `pds` command
# on your PATH. No sudo, nothing written outside your home directory.

set -euo pipefail

APP_NAME="Package Deployer Studio"
INSTALL_DIR="$HOME/.local/share/package-deployer-studio"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/pds"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

echo
bold "  $APP_NAME - companion"
printf '  \033[90m%s\033[0m\n' "-------------------------------------------"
echo

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f  "$LAUNCHER"      && ok "removed $LAUNCHER"      || true
  rm -rf "$INSTALL_DIR"   && ok "removed $INSTALL_DIR"   || true
  echo
  info "Your settings in ~/.pdstudio were left alone. Delete them with:"
  info "  rm -rf ~/.pdstudio"
  echo
  exit 0
fi

# ------------------------------------------------------------------ checks
OS="$(uname -s)"
case "$OS" in
  Darwin) info "Platform      : macOS $(sw_vers -productVersion 2>/dev/null || echo '')" ;;
  Linux)  info "Platform      : Linux" ;;
  *)      bad "Unsupported platform: $OS"; exit 1 ;;
esac

MISSING=0

if command -v pwsh >/dev/null 2>&1; then
  ok "PowerShell    : $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"
else
  bad "PowerShell 7 (pwsh) is not installed - it is required."
  if [[ "$OS" == "Darwin" ]]; then
    info "  brew install --cask powershell"
  else
    info "  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
  fi
  MISSING=1
fi

if command -v dotnet >/dev/null 2>&1; then
  ok "dotnet SDK    : $(dotnet --version 2>/dev/null)"
else
  warn "dotnet SDK not found - needed to install the PAC CLI and to build packages."
  if [[ "$OS" == "Darwin" ]]; then
    info "  brew install --cask dotnet-sdk"
  else
    info "  https://dotnet.microsoft.com/download"
  fi
fi

PAC_BIN=""
if command -v pac >/dev/null 2>&1; then
  PAC_BIN="$(command -v pac)"
elif [[ -x "$HOME/.dotnet/tools/pac" ]]; then
  PAC_BIN="$HOME/.dotnet/tools/pac"
fi

if [[ -n "$PAC_BIN" ]]; then
  ok "PAC CLI       : $PAC_BIN"
else
  warn "PAC CLI (pac) not found."
  if command -v dotnet >/dev/null 2>&1; then
    echo
    read -r -p "  Install it now with dotnet tool install? [Y/n] " reply
    reply="${reply:-Y}"
    if [[ "$reply" =~ ^[Yy] ]]; then
      dotnet tool install --global Microsoft.PowerApps.CLI.Tool || \
        dotnet tool update --global Microsoft.PowerApps.CLI.Tool || true
      if [[ -x "$HOME/.dotnet/tools/pac" ]]; then ok "PAC CLI installed"; PAC_BIN="$HOME/.dotnet/tools/pac"; fi
    fi
  fi
fi

if [[ "$MISSING" -eq 1 ]]; then
  echo
  bad "Install the missing prerequisites above, then run this again."
  echo
  exit 1
fi

# ----------------------------------------------------------------- install
echo
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

for f in pds.ps1 README.md LICENSE; do
  if [[ -f "$SRC_DIR/$f" ]]; then
    cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
  fi
done
ok "copied the companion to $INSTALL_DIR"

# macOS tags anything downloaded with a quarantine attribute; clear it so the
# script runs without Gatekeeper prompts. This is the macOS equivalent of the
# Zone.Identifier stream on Windows.
if [[ "$OS" == "Darwin" ]]; then
  if xattr -d -r com.apple.quarantine "$INSTALL_DIR" 2>/dev/null; then
    ok "cleared the macOS quarantine flag"
  else
    info "no quarantine flag to clear"
  fi
fi

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
exec pwsh -NoProfile -File "$INSTALL_DIR/pds.ps1" "\$@"
EOF
chmod +x "$LAUNCHER"
ok "created the launcher $LAUNCHER"

# --------------------------------------------------------------- PATH help
echo
if command -v pds >/dev/null 2>&1; then
  ok "'pds' is on your PATH"
else
  warn "$BIN_DIR is not on your PATH yet."
  SHELL_RC="$HOME/.zshrc"
  [[ "${SHELL:-}" == *bash* ]] && SHELL_RC="$HOME/.bashrc"
  info "Add this line to $SHELL_RC, then open a new terminal:"
  echo
  printf '        export PATH="$PATH:%s:$HOME/.dotnet/tools"\n' "$BIN_DIR"
  echo
  read -r -p "  Add it for you now? [Y/n] " reply
  reply="${reply:-Y}"
  if [[ "$reply" =~ ^[Yy] ]]; then
    {
      echo ''
      echo '# Package Deployer Studio companion'
      echo "export PATH=\"\$PATH:$BIN_DIR:\$HOME/.dotnet/tools\""
    } >> "$SHELL_RC"
    ok "appended to $SHELL_RC - open a new terminal, or run: source $SHELL_RC"
  fi
fi

# ------------------------------------------------------------------- done
echo
bold "  Installed."
echo
info "Run it with:   pds"
info "Check tools:   pds doctor"
echo
warn "One thing to know about deploying from macOS:"
info "Microsoft ships 'pac package deploy' for Windows only, and the Package"
info "Deployer GUI tool is a Windows application. On macOS this companion"
info "deploys by importing each solution in the order the package declares."
info "That covers packages that only ship solutions. If yours runs custom"
info "package code or imports configuration data, deploy it from Windows -"
info "'pds pipeline' writes a GitHub Actions workflow that does exactly that."
echo
