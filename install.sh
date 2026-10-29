#!/bin/sh
# Builds, installs to ~/Applications, enables start at login, and (re)launches.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x Hoverpad && sleep 0.5 || true
mkdir -p ~/Applications
rm -rf ~/Applications/Hoverpad.app
cp -R Hoverpad.app ~/Applications/
open ~/Applications/Hoverpad.app --args --enable-login
echo "Installed ~/Applications/Hoverpad.app (starts at login)"
