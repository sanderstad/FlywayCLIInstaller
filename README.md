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
  uses: sanderstad/FlywayCLIInstaller@v0.1
  with:
    version: 'latest' # or specify a version, e.g. '11.8.2'
```

## Inputs

| Name    | Description                       | Required | Default  |
|---------|-----------------------------------|----------|----------|
| version | Flyway CLI version to install     | false    | latest   |

## Example Workflow

```yaml
jobs:
  flyway-setup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Flyway CLI
        uses: sanderstad/FlywayCLIInstaller@v0.1
        with:
          version: 'latest'
```

## How it works

1. **Detects OS** and sets the correct download filename.
2. **Downloads** the Flyway CLI archive from the official source.
3. **Extracts** the archive to a local directory.
4. **Adds Flyway to PATH** so it can be used in subsequent workflow steps.
5. **Validates** the installation by running the version command.

## Notes

- No custom Flyway parameters are set; only the CLI is installed and validated.
- If you encounter errors about unknown Flyway parameters, ensure you are not passing custom environment variables as Flyway CLI arguments.

## License

MIT


