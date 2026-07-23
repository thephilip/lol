#!/usr/bin/env bash
# install.sh — install lol
#
# Usage:
#   bash install.sh
#   bash install.sh --uninstall
#
# Environment overrides:
#   LOL_INSTALL_DIR   where the repo is cloned  (default: ~/.local/share/lol)
#   LOL_BIN_DIR       where the symlink is made  (default: ~/.local/bin)

set -euo pipefail

REPO="https://github.com/thephilip/lol"
INSTALL_DIR="${LOL_INSTALL_DIR:-$HOME/.local/share/lol}"
BIN_DIR="${LOL_BIN_DIR:-$HOME/.local/bin}"
BIN_LINK="$BIN_DIR/lol"

# ── Colors (best-effort) ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
  G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' B='\033[1m' D='\033[2m' Z='\033[0m'
else
  G='' Y='' R='' B='' D='' Z=''
fi

ok()   { printf "${G}[  OK  ]${Z} %s\n" "$*"; }
warn() { printf "${Y}[ WARN ]${Z} %s\n" "$*"; }
err()  { printf "${R}[  ERR ]${Z} %s\n" "$*" >&2; }
info() { printf "${D}[ INFO ]${Z} %s\n" "$*"; }
step() { printf "\n${B}==> %s${Z}\n" "$*"; }

# ── Uninstall ─────────────────────────────────────────────────────────────
uninstall() {
  step "Uninstalling lol"

  if [[ -L "$BIN_LINK" ]]; then
    rm "$BIN_LINK"
    ok "Removed symlink: $BIN_LINK"
  else
    info "No symlink found at $BIN_LINK"
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    read -rp "Remove install directory $INSTALL_DIR? [y/N] " confirm
    if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      rm -rf "$INSTALL_DIR"
      ok "Removed: $INSTALL_DIR"
    else
      info "Kept: $INSTALL_DIR"
    fi
  fi

  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lol"
  if [[ -d "$config_dir" ]]; then
    read -rp "Remove context data at $config_dir? [y/N] " confirm
    if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
      rm -rf "$config_dir"
      ok "Removed: $config_dir"
    else
      info "Kept: $config_dir"
    fi
  fi

  # Remove completion file if found
  local candidate
  for candidate in \
    "${ZDOTDIR:-$HOME}/.zfunc/_lol" \
    "$HOME/.local/share/zsh/site-functions/_lol" \
    "$HOME/.zsh/completions/_lol"; do
    if [[ -f "$candidate" ]]; then
      read -rp "Remove zsh completion at $candidate? [y/N] " confirm
      if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
        rm -f "$candidate"
        ok "Removed: $candidate"
      else
        info "Kept: $candidate"
      fi
    fi
  done

  # Remove shell integration lines if present
  local rc
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [[ -f "$rc" ]] && grep -qF 'lol shell-init' "$rc" 2>/dev/null; then
      read -rp "Remove lol shell integration from $rc? [Y/n] " confirm
      if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
        grep -vF 'lol shell-init' "$rc" \
          | grep -v '^# lol shell integration$' \
          > "${rc}.loltmp" && mv "${rc}.loltmp" "$rc"
        ok "Removed shell integration from $rc"
      else
        info "Kept: $rc"
      fi
    fi
  done

  ok "Done."
}

# ── Dependency check ──────────────────────────────────────────────────────
check_deps() {
  local missing=()
  command -v git  &>/dev/null || missing+=("git")
  command -v bash &>/dev/null || missing+=("bash")
  command -v omc  &>/dev/null || warn "'omc' not found — required for most lol commands. See: https://github.com/gmeghnag/omc"

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required dependencies: ${missing[*]}"
    exit 1
  fi
}

# ── Install ───────────────────────────────────────────────────────────────
install() {
  step "Installing lol"
  check_deps

  # Clone or update
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Found existing install at $INSTALL_DIR — updating"
    git -C "$INSTALL_DIR" pull --ff-only origin main --quiet
    ok "Updated to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
  else
    info "Cloning into $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --quiet "$REPO" "$INSTALL_DIR"
    ok "Cloned $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
  fi

  chmod +x "$INSTALL_DIR/lol"

  # Symlink
  step "Linking into PATH"
  mkdir -p "$BIN_DIR"

  if [[ -e "$BIN_LINK" && ! -L "$BIN_LINK" ]]; then
    err "$BIN_LINK exists and is not a symlink — remove it manually and re-run"
    exit 1
  fi

  ln -sf "$INSTALL_DIR/lol" "$BIN_LINK"
  ok "Symlinked: $BIN_LINK → $INSTALL_DIR/lol"

  # PATH check
  step "Checking PATH"
  if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    ok "$BIN_DIR is in your PATH"
  else
    warn "$BIN_DIR is not in your PATH"
    echo
    echo "  Add one of the following to your shell profile:"
    echo
    printf "  ${B}bash / zsh:${Z}  export PATH=\"\$HOME/.local/bin:\$PATH\"\n"
    printf "  ${B}fish:${Z}        fish_add_path \$HOME/.local/bin\n"
    echo
  fi

  # Zsh completions (optional)
  step "Zsh completions"
  local comp_src="$INSTALL_DIR/completions/_lol"
  if [[ -f "$comp_src" ]]; then
    # Try to find a user completions dir already in fpath
    local comp_dest=""
    local candidate
    for candidate in \
      "${ZDOTDIR:-$HOME}/.zfunc" \
      "$HOME/.local/share/zsh/site-functions" \
      "$HOME/.zsh/completions"; do
      if [[ -d "$candidate" ]]; then
        comp_dest="$candidate"
        break
      fi
    done

    if [[ -n "$comp_dest" ]]; then
      read -rp "  Install zsh completion to $comp_dest/_lol? [Y/n] " confirm
      if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
        cp "$comp_src" "$comp_dest/_lol"
        ok "Installed: $comp_dest/_lol"
      else
        info "Skipped. Install manually: lol completion zsh > ~/.zfunc/_lol"
      fi
    else
      info "No zsh completions directory detected."
      echo
      echo "  To enable tab completion, add this to your ~/.zshrc:"
      echo
      printf "  ${B}mkdir -p ~/.zfunc${Z}\n"
      printf "  ${B}lol completion zsh > ~/.zfunc/_lol${Z}\n"
      printf "  ${B}# ensure this is before compinit in your .zshrc:${Z}\n"
      printf "  ${B}fpath=(~/.zfunc \$fpath)${Z}\n"
      echo
    fi
  fi

  # Shell integration (optional)
  step "Shell integration (prompt indicator)"
  echo "  Adds a [lol:<context>/<cluster>] indicator to your shell prompt"
  echo "  when a named context is active."
  echo

  local rc_file=""
  if [[ -n "${ZSH_VERSION:-}" || "${SHELL:-}" == */zsh ]]; then
    rc_file="${ZDOTDIR:-$HOME}/.zshrc"
  elif [[ -n "${BASH_VERSION:-}" || "${SHELL:-}" == */bash ]]; then
    rc_file="$HOME/.bashrc"
  fi

  local eval_line='eval "$(lol shell-init)"'
  if [[ -n "$rc_file" ]]; then
    if grep -qF 'lol shell-init' "$rc_file" 2>/dev/null; then
      ok "Shell integration already present in $rc_file"
    else
      read -rp "  Add shell integration to $rc_file? [Y/n] " confirm
      if [[ "$(printf '%s' "$confirm" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
        printf '\n# lol shell integration\n%s\n' "$eval_line" >> "$rc_file"
        ok "Added to $rc_file"
        info "Restart your shell or run: source $rc_file"
      else
        info "Skipped. Add manually: $eval_line"
      fi
    fi
  else
    info "Could not detect shell rc file."
    echo "  Add manually to your shell profile:"
    printf "  ${B}%s${Z}\n" "$eval_line"
  fi

  step "Done"
  ok "lol installed. Run: lol --version"
  printf '\n  %s\n' "Runtime data will be stored in: ${XDG_CONFIG_HOME:-$HOME/.config}/lol/"
  echo
}

# ── Entry point ───────────────────────────────────────────────────────────
case "${1:-}" in
  --uninstall|-u) uninstall ;;
  "")             install ;;
  *) printf 'Usage: %s [--uninstall]\n' "$(basename "$0")"; exit 1 ;;
esac
