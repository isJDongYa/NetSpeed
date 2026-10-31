# Contributing to NetSpeed

Issues and pull requests are welcome in English or Simplified Chinese.

## Before sending a change

1. Build with `zsh scripts/build.sh`.
2. Run `delivery/NetSpeed.app/Contents/MacOS/NetSpeed --self-test`.
3. For display changes, check both light and dark appearances, short and long speed values, and menu bar click behavior.
4. For network changes, describe which interfaces and connection transitions you tested. For login-item changes, verify the resulting state in System Settings.

Keep the app small and local. Do not introduce telemetry, outgoing requests, new permissions, or third-party dependencies without discussing the change in an issue first.

## Reporting a bug

Include the macOS version, Apple Silicon or Intel architecture, steps to reproduce, expected behavior, and actual behavior. If you include a screenshot or diagnostic output, remove addresses and other information you do not want to publish.

## Scope of checks

Automated checks cover calculations, system data parsing, and measured layout width. Interactive appearance, sleep/wake, login behavior, and testing across macOS versions require separate validation. A passing build does not establish those results.

## License

By contributing, you agree that your contributions will be licensed under the project's [MIT License](LICENSE).
