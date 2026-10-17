# Binary publishing workflow

When the user pastes an MCP server definition and asks for binaries, use the
definition to create standalone Bun CLIs for both Linux x64 and Windows x64.

- Preserve the complete server definition, including HTTP headers and env
	references. Never print secret values in responses or logs.
- Use `npx mcporter generate-cli --runtime bun --compile <name>` for the Linux
	binary.
- For Windows, generate a temporary Bun bundle and cross-compile it with
	`npx bun build <bundle>.js --compile --target bun-windows-x64 --outfile <name>.exe`.
	Remove the temporary bundle afterward.
- Verify the Linux binary with `--help` and verify both file formats with
	`file`: Linux must be ELF x86-64 and Windows must be PE32+ x86-64.
- Require an authenticated `cf` CLI, then run
	`./scripts/upload-binaries.sh` to upload the generated artifacts to the
	existing `cli-porter` R2 bucket. Use `CF_R2_BUCKET` only when the user names
	another bucket.


The upload script accepts explicit files when only a subset should be
published, for example `./scripts/upload-binaries.sh example example.exe`.
