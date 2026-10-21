#!/usr/bin/env bash
set -e

echo "🚀 Installing Yoke (Yoke)..."

# Ensure system build dependencies on Debian/Ubuntu
if command -v apt-get >/dev/null 2>&1; then
    echo "📦 Checking system dependencies (libgit2-dev, build-essential)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq libgit2-dev build-essential >/dev/null 2>&1 || true
fi

# Clone or update repository
INSTALL_DIR="$HOME/.yoke/source"
if [ -d "$INSTALL_DIR" ]; then
    echo "🔄 Updating existing source in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" pull --rebase
else
    echo "📥 Cloning Yoke repository..."
    git clone https://github.com/Oeditus/yoke.git "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

echo "🔨 Building OTP release..."
mix deps.get
MIX_ENV=prod mix release --overwrite

mkdir -p "$HOME/.local/bin"
WRAPPER="$HOME/.local/bin/yoke"
RELEASE_BIN="$INSTALL_DIR/_build/prod/rel/yoke/bin/yoke"

cat <<EOF > "$WRAPPER"
#!/usr/bin/env bash
set -e
export YOKE_WORKSPACE="\$PWD"
export YOKE_REPO_DIR="$INSTALL_DIR"
export DLLB_DIR="\${DLLB_DIR:-\$(cd "$INSTALL_DIR/../dllb" 2>/dev/null && pwd || echo "$INSTALL_DIR/../dllb")}"
if [ -z "\${DLLB_SERVER_BIN:-}" ]; then
  if [ -f "\$DLLB_DIR/target/release/dllb-server" ]; then
    export DLLB_SERVER_BIN="\$DLLB_DIR/target/release/dllb-server"
  elif [ -f "\$DLLB_DIR/target/debug/dllb-server" ]; then
    export DLLB_SERVER_BIN="\$DLLB_DIR/target/debug/dllb-server"
  fi
fi
cd "\$PWD"
if [ -t 0 ]; then
  stty -ixon 2>/dev/null || true
fi
exec "$INSTALL_DIR/yoke" --prod "\$@"
EOF

chmod +x "$WRAPPER"

echo ""
echo "✅ Yoke installed successfully!"
echo "📍 Location: $WRAPPER"
echo ""
echo "Ensure '$HOME/.local/bin' is in your PATH:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
echo ""
echo "Now run 'yoke' from any project directory!"
