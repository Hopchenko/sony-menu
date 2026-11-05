# Contributing

Sony Headphone Control is a small native Swift application. It has no third-party package
dependencies. Start with `zsh build.sh` and `zsh test.sh` on macOS with Xcode.

Tests use simulated Bluetooth and macOS services; the normal test suite does
not connect to headphones or alter system login settings. Native panel
previews and an LLVM coverage report are generated under `build/`.

Changes to the Sony protocol should include wire fixtures or simulated-device
tests. Keep all connection and audio observers removable on shutdown, use
notifications rather than repeating timers, and never modify unrelated audio
devices. New controls should display state read back from the headset.

For device reports, include the headphone model, firmware, macOS version, and
the specific behavior you expected. WH-1000XM3 is currently the only validated
model; a shared Sony service UUID alone does not establish compatibility.

See [TESTING.md](TESTING.md) for live diagnostics and remaining manual checks.
