# Repository instructions

## Releases

Every Noren version release must keep all installation channels in sync.

1. Update the version in the source, package metadata, README, and versioned
   documentation.
2. Review `install.sh` and confirm that the tagged release publishes it
   together with both Linux binaries and `checksums.txt`.
3. After the GitHub Release is live, manually update
   `Makuraryu/homebrew-tap/Formula/noren.rb` with the new tag URL, source
   archive SHA-256, and test version.
4. Test both the release installer and the Homebrew formula.

Do not automate writes to `Makuraryu/homebrew-tap`. The Tap update is an
intentional manual release step. Follow
[`docs/releasing.md`](docs/releasing.md) for the complete checklist.
