# Publication and privacy

The repository is prepared as a source project. Compatibility reports contain model/software information and outcomes, without raw personal device captures.

Before making a repository or release public, inspect both tracked files **and Git history** for personal names, email addresses, home-directory paths, device serials, personal device names, SSIDs, network addresses, credentials and certificate identities. Deleting a file in a later commit does not remove its earlier contents from history.

Use repository-local Git identity settings if a personal global identity should not appear in commit metadata. This repository's initial commit uses the generic label `anDrop contributors` and a non-deliverable `example.invalid` address. GitHub still shows the repository owner, and account activity may link to the owner. Public commit-signing metadata and signed release certificates can also identify their signers.

Keep real device logs, private screenshots, captures, fixtures and release artifacts in ignored directories. The reviewed mock UI images under `docs/images/` are an intentional documentation exception; regenerate them only with fictional data as described in that folder. `.gitignore` is a guard against accidental staging, not a secret detector. Check staged files explicitly. Existing private test artifacts outside this repository are not suitable release assets.

The source does not contain a fixed personal Computer Name. At runtime the app intentionally follows the user's system Computer Name and advertises it to nearby devices, as described in [usage](usage.md).

Upstream authors' copyright names and notices in `ThirdPartyNotices` are retained for attribution. They are not the project owner's personal metadata.

Official brand artwork has separate provenance and rights in `Resources/BrandLogos/README.md`; include it in the publication review. The source-code license does not grant rights to those logos.
