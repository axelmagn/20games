#!/bin/bash
set -exuo pipefail
zig build -Dtarget=wasm32-emscripten
