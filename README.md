# Flyway CLI Installer

A GitHub Action to automatically download, install, and validate the [Flyway CLI](https://flywaydb.org/documentation/usage/commandline/) on your workflow runner.  
Supports both Linux and Windows environments.

## Features

- Downloads the specified Flyway CLI version (or latest)
- Handles extraction and setup for both Linux (`tar.gz`) and Windows (`zip`)
- Adds Flyway to the system `PATH`
- Validates the installation by running `flyway --version` or `flyway -v`

## Usage

```yaml
- name: Install Flyway CLI
  uses: sanderstad/FlywayCLIInstaller@v1
  with:
    version: 'latest' # or specify a version, e.g. '11.8.2'
```

## Inputs

| Name                | Description                                                                        | Required | Default |
| ------------------- | ---------------------------------------------------------------------------------- | -------- | ------- |
| version             | Flyway CLI version to install                                                      | false    | latest  |
| retry-count         | Number of attempts for network calls to Red Gate (metadata fetch and CLI download) | false    | 3       |
| retry-delay-seconds | Delay in seconds between retry attempts for network calls                          | false    | 5       |

## Example Workflow

```yaml
jobs:
  flyway-setup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Flyway CLI
        uses: sanderstad/FlywayCLIInstaller@v1
        with:
          version: 'latest'
```

## How it works

1. **Detects OS** and sets the correct download filename.
2. **Downloads** the Flyway CLI archive from the official source, retrying on transient failures (see `retry-count` / `retry-delay-seconds` above).
3. **Extracts** the archive to a local directory.
4. **Adds Flyway to PATH** so it can be used in subsequent workflow steps.
5. **Validates** the installation by running the version command.

Network calls to Red Gate's download server (both the version-metadata lookup and the archive download) are retried up to `retry-count` times, `retry-delay-seconds` apart, before the action fails. This helps with intermittent `403` responses from the server.

## Releases

Every push to `main` is automatically versioned and released — no manual tagging. The version bump is determined from commit messages since the last release, following [Conventional Commits](https://www.conventionalcommits.org/):

- `fix: ...` → patch release (e.g. `v1.0.0` → `v1.0.1`)
- `feat: ...` → minor release (e.g. `v1.0.1` → `v1.1.0`)
- `feat!: ...`, `fix!: ...`, or a `BREAKING CHANGE:` footer → major release (e.g. `v1.1.0` → `v2.0.0`)
- Anything else (`chore:`, `docs:`, `ci:`, etc.) does not trigger a release on its own

This repo merges pull requests via squash merge, so the PR title becomes the commit message that gets classified — use a Conventional Commits prefix in your PR title.

Each release also moves a floating major-version tag (e.g. `v1`) to point at the latest release in that major line, so `uses: sanderstad/FlywayCLIInstaller@v1` always tracks the newest compatible release. Pin an exact `vX.Y.Z` tag instead if you need a fully immutable reference.

## Notes

- No custom Flyway parameters are set; only the CLI is installed and validated.
- If you encounter errors about unknown Flyway parameters, ensure you are not passing custom environment variables as Flyway CLI arguments.

## License

MIT


