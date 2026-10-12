# Contributing to Spookky

Spookky is a native macOS workspace around real terminals. Contributions should protect immediate shell access, input behavior, session ownership, and bounded resource use.

## Start here

Read the [product contract](docs/product.md), [current status](docs/status.md), and [development setup](docs/development.md). The status document lists known limitations. The HTML prototype is a simulation, not proof of native behavior.

For a bug, describe the steps, expected result, actual result, app version, macOS version, and architecture. Remove prompts, credentials, private paths, and terminal contents from attachments. Report vulnerabilities privately through [the security policy](SECURITY.md).

For a larger feature, open a proposal before implementation. State the user need, smallest useful interaction, and added resource or state cost. Existing issues are not a promise that a change will be accepted.

## Development

Fork the repository and create a branch for one concern. Do not include generated build outputs, private fixtures, or local state. Registration and opening a user's project must never install dependencies or run its setup scripts.

Run the checks in [development](docs/development.md). Explain what changed, why, what you tested, and what remains unverified. Native input or lifecycle changes need evidence from the running app. UI changes need both themes and narrow layouts.

Keep Swift process launches as argument arrays. Never interpolate a path or prompt into a shell command. Operate only on Spookky's owned runtime and isolated test folders.

## Review and license

The maintainer reviews incoming changes. Keep pull requests focused and follow the [code of conduct](CODE_OF_CONDUCT.md). Contributions are accepted under the [MIT license](LICENSE). Retain third-party notices and document adopted dependencies in [THIRD_PARTY.md](THIRD_PARTY.md).
