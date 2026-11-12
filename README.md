# VaultPanel

VaultPanel is a web control panel for Linux servers: connect a server, then deploy and run
websites and apps with their domains, databases, SSL, monitoring, backups and security.

This repository holds what installs it: the installer, the package repository and the downloads,
served at [installer.vaultpanel.net](https://installer.vaultpanel.net). Report problems and ask
questions in [Issues](https://github.com/VaultPanel/packages/issues).

**Latest version: 0.4.0**

## Install

On a fresh server with Ubuntu 22.04, 24.04 or 26.04, or Debian 12 or 13 (2 GB of memory or more
recommended), as root. First update the system and make sure `curl` and `sudo` are there:

```sh
apt update && apt -y upgrade && apt -y install curl wget sudo
```

Then download the installer, check it and run it, with the database server you want for your
websites and apps:

```sh
curl -sS https://installer.vaultpanel.net/v2/install.sh -o install.sh; \
echo "37779be96c4732cf4fdf5a39a6786b1de60f5361c44bcce4a0f2baaf26495d57 install.sh" | \
sha256sum -c && sudo DB_ENGINE=MARIADB_12.3 bash install.sh
```

| System           | `DB_ENGINE`                                       |
| ---------------- | ------------------------------------------------- |
| Ubuntu 26.04 LTS | `MARIADB_12.3`, `MARIADB_11.8`                    |
| Ubuntu 24.04 LTS | `MARIADB_12.3`, `MARIADB_11.4`, `MARIADB_10.11`   |
| Ubuntu 22.04 LTS | `MARIADB_11.4`, `MARIADB_10.11`, `MARIADB_10.6`   |
| Debian 13        | `MARIADB_12.3`, `MARIADB_11.8`                    |
| Debian 12        | `MARIADB_12.3`, `MARIADB_11.4`, `MARIADB_10.11`   |

MySQL 8.4 and 8.0 come in a later version. Without `DB_ENGINE` the installer takes the newest
MariaDB for your system; `DB_ENGINE=NONE` installs no database server.

The installer sets up Node.js 22 and Docker, adds VaultPanel's package repository (checking its
signing key, fingerprint `79B3 4D79 D2A7 D0DE 54A3 D906 B62A 47C2 ED27 75A6`) and installs the
`vaultpanel` package. At the end it prints the panel's address and a setup token for the owner
account.

## Update and roll back

```sh
sudo vaultpanel update      # the newest version (backs the panel up first)
sudo vaultpanel rollback    # back to the version before the last update, with its database
```

`apt upgrade` updates VaultPanel too. The repository keeps the newest versions: 0.4.0 0.3.2 0.3.0 0.2.1 0.2.0.

## Downloads

- [WHMCS module](https://installer.vaultpanel.net/downloads/vaultpanel-whmcs.zip): sell VaultPanel
  hosting from WHMCS (MIT license; checksums in
  [SHA256SUMS](https://installer.vaultpanel.net/downloads/SHA256SUMS)).
- The SDK and the command-line tool are on npm: `@vaultpanel/sdk`, `@vaultpanel/cli`.

## License

VaultPanel is free to use under the [VaultPanel License](LICENSE), which also comes with the
package (`/usr/share/doc/vaultpanel/copyright`). The WHMCS module, the SDK and the command-line tool
are MIT licensed.

## Security

Report security problems privately: **Security > Report a vulnerability** on this repository, never
in a public issue.
