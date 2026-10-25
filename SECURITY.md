# Security

Please report a suspected vulnerability through this repository's GitHub
**Security → Report a vulnerability** entry when available. If private reporting
is unavailable, open an issue requesting a private reporting channel without
including exploit details or sensitive data. There is no published response-time
or backport guarantee; fixes target the current development branch.

Profiling builds and runs the target project's code. Use projects you trust,
or an isolated environment appropriate for running untrusted software. The MCP
server exposes profiling operations to its client; configure it only for clients
and working directories you trust. It refuses to run binaries Lake did not build,
to write files outside the project and to signal anything but a single process.
The [security review](docs/reviews/security-review.md) lists what each component
guards against and the risks accepted by design. Reports can contain source paths, names and
program diagnostics: inspect them before sharing.

Release archives include SHA256 checksums for integrity checking. These are
distributed with the release and are not an independent signature of its
publisher. Supported toolchains and platforms are described in
[CONTRIBUTING.md](CONTRIBUTING.md).
