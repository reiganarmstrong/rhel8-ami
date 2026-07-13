# Vendored Packer plugins

This tree follows Packer's required namespaced plugin layout and is selected by
the repository-root `packer-wrapper.sh` launcher through `PACKER_PLUGIN_PATH`.

## Amazon

- Version: 1.8.1
- Platform: Linux amd64
- Plugin API: x5.0
- Upstream archive: `packer-plugin-amazon_1.8.1_linux_amd64.zip`
- Upstream URL: <https://releases.hashicorp.com/packer-plugin-amazon/1.8.1/packer-plugin-amazon_1.8.1_linux_amd64.zip>
- Upstream archive SHA-256: `67cc6b972b4baf9d57d48a6833b9066700fc29a2ad05482ba28173164ab97557`
- Extracted binary SHA-256: `13b0662a04fddb0c2e04252be8b6b64812c28ce33fe8cc9d6243518aae0bff17`

The adjacent `_SHA256SUM` file contains the raw extracted-binary digest in the
format required for modern Packer to discover the plugin. The repository
wrapper does not independently calculate or compare this digest. When updating
the plugin, update the exact version constraint and binary path in
`rhel8.pkr.hcl` and the root wrapper together.
