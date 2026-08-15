#!/usr/bin/env bash
# Activa el toolchain Swift 6.3.3 para Linux (Ubuntu 24.04 build, compatible con 26.04).
export SWIFT_HOME="$HOME/.local/swift/swift-6.3.3-RELEASE-ubuntu24.04"
export COMPAT_LIBS="$HOME/.local/compat"
export PATH="$SWIFT_HOME/usr/bin:$PATH"
export LD_LIBRARY_PATH="$COMPAT_LIBS:$SWIFT_HOME/usr/lib/swift/linux:$LD_LIBRARY_PATH"
