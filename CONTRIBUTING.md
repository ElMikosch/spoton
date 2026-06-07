# Contributing to SpotOn

Thank you for your interest in contributing to SpotOn.

## Prerequisites

- **Perl 5.36+** — LMS ships 5.36 (LMS 8.5) through 5.38 (LMS 9.x)
- **git**

No LMS installation is required. The test suite runs standalone using built-in stubs that
mock all LMS modules (`Slim::Utils::Log`, `Slim::Utils::Prefs`, `Slim::Utils::Cache`, etc.).
No CPAN setup is needed — all test dependencies are Perl core modules.

## Running Tests

```
prove t/
```

Expected output: 12 test files, 230 tests, completes in under 1 second.

All test modules are Perl core: `Test::More`, `File::Temp`, `JSON::PP`, `File::Path`, `Cwd`.

To run a single test file:

```
perl t/05_perl_syntax.t
```

## Project Structure

```
Plugins/SpotOn/          Plugin source (Perl modules)
  Plugin.pm              Entry point, menu registration
  API/                   Spotify Web API client + token management
  Connect/               librespot process management + Spirc sync
  ProtocolHandler.pm     spoton:// URI scheme handler
  Settings.pm            LMS settings page

t/                       Test suite (12 files, ~230 tests)
  00_load.t              Module load check
  05_perl_syntax.t       Perl syntax check with LMS stub framework
  ...

.github/workflows/       CI pipelines
  perl-tests.yml         Perl test matrix (5.36 + 5.38)
  build-librespot.yml    librespot cross-compilation

Plugins/SpotOn/Bin/      librespot binaries (per architecture, auto-selected)
  x86_64-linux/
  aarch64-linux/
  armhf-linux/
  ...
```

## Pull Request Guidelines

1. Branch from `main`
2. Write a descriptive PR title and body explaining what changed and why
3. CI must pass — both Perl 5.36 and 5.38 matrix jobs
4. Keep changes focused — one logical change per PR
5. For new features, include tests in `t/`
6. For bug fixes, include a regression test when practical

For questions, open a GitHub Discussion or visit the
[Lyrion Community Forum](https://forums.slimdevices.com/).
