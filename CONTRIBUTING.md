# Contributing to Vitrine

Thanks for helping. Bug reports, tested fixes and new guest support are all welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Vitrine is clean-room. Do not submit code copied from, or derived from inspecting, proprietary
  virtualization products, and do not copy GPL code into this Apache-2.0 code base. QEMU, Samba and
  swtpm stay separate programs that Vitrine launches.
- By contributing you agree that your contribution is licensed under the Apache License 2.0.

## Building and testing

```bash
swift build && swift test
python3 scripts/tests/lifecycle-integrity.py "$(swift build -c release --show-bin-path)/vitrinectl"
(cd guest/linux-agent && go vet ./... && go test ./...)
```

See the README for building the app and agents and for the smoke tests that boot real guests. If you
change `guest/linux-agent/go.mod`, run `./scripts/make-notices.sh` and commit the updated
`THIRD_PARTY_NOTICES`.

Features that touch a backend should be checked in a real guest, not only in unit tests. Say in the
pull request which host macOS version and guests you tested.

## Translations

The app is available in English, Traditional Chinese, Simplified Chinese and Japanese. Its strings
live in one String Catalog, `Sources/VitrineApp/Resources/Localizable.xcstrings`; the permission
prompts are in `Resources/<language>.lproj/InfoPlist.strings`. `vitrinectl`, the MCP server and
error details from the VM backends stay in English.

- After changing UI text, run `./scripts/dev/update-strings.sh`. It adds new strings to the catalog,
  marks removed ones stale and prints how many are untranslated per language.
- Translate in Xcode (open the `.xcstrings` file) or edit the JSON. Keep format specifiers (`%@`,
  `%lld`) and use positional ones (`%1$@`) if the order changes. Follow Apple's wording for macOS terms
  in that language.
- To add a language, add its code to the catalog (Xcode: "+" in the catalog editor), translate, and
  copy `Resources/en.lproj/InfoPlist.strings` to `Resources/<code>.lproj/`. `scripts/build-app.sh`
  picks up every language it finds.
- Check the result with `open dist/Vitrine.app --args -AppleLanguages '(ja)'`.

## Pull requests

- Keep each pull request to one change, with tests where practical.
- Match the surrounding code style. Comments explain why, not what.
- Describe user-visible changes and any manual test steps in the pull request.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
