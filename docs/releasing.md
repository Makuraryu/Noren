# Releasing Noren

Noren has two installation channels that must be updated for every version:

- the Linux installer and static binaries in the GitHub Release;
- the manually maintained Homebrew formula in
  [`Makuraryu/homebrew-tap`](https://github.com/Makuraryu/homebrew-tap).

The Homebrew Tap update is deliberately manual. Do not add a token or workflow
that writes to the Tap repository.

## Release checklist

1. Choose a new semantic version and update every version reference:

   ```sh
   rg '0\.[0-9]+\.[0-9]+' README.md build.zig.zon src docs
   ```

2. Review `install.sh`. It does not hard-code the current version, but the
   release must contain the copy from the release tag.
3. Run the full validation suite:

   ```sh
   zig fmt --check src tests build.zig
   zig build test
   zig build test-integration
   zig build test-e2e
   ```

4. Merge the release changes, create and push the matching `vX.Y.Z` tag, and
   wait for the Release workflow.
5. Confirm that the GitHub Release is marked latest and contains:

   ```text
   install.sh
   noren-linux-aarch64
   noren-linux-x86_64
   checksums.txt
   ```

6. Test the public Linux installer in a clean temporary directory:

   ```sh
   install_dir=$(mktemp -d)
   curl -fsSL https://github.com/Makuraryu/Noren/releases/latest/download/install.sh \
     | env NOREN_INSTALL_DIR="$install_dir" sh
   "$install_dir/noren" version
   ```

7. Calculate the new source archive checksum:

   ```sh
   curl -fsSL "https://github.com/Makuraryu/Noren/archive/refs/tags/vX.Y.Z.tar.gz" \
     | shasum -a 256
   ```

8. Manually update `Formula/noren.rb` in `Makuraryu/homebrew-tap`:

   - change the tag in `url`;
   - replace `sha256` with the source archive checksum;
   - update the expected version in the `test` block.

9. Commit and push the Tap change, then verify:

   ```sh
   brew update
   brew upgrade noren
   brew test noren
   noren version
   ```

10. Check the README commands one final time. The latest installer and
    Homebrew must report the same version.
