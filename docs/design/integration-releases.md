# Integration releases

Core and integrations ship as separate versioned artifacts. The core bundle contains the platform modules and target-specific host archives. An integration bundle contains its package root and modules. The compatibility manifest records which core was validated with each integration.

During development, `artifact.kind` is `local`, `location` names the repository platform root, and `content_sha256` hashes the source globs declared by the manifest (platform Roc modules, the TOML package, and host Zig sources). Even private helper or comment changes invalidate this conservative source lock. For a published artifact, use `kind = url`, an HTTPS bundle location, and the SHA-256 of the distributed archive. Keep published manifests immutable with their release assets.

Each integration entry records its version, package root, supported `platform_versions`, validated platform digest, positive E2E application, verification script, compatibility digest, and maximum expanded package size. The compatibility digest includes package and E2E inputs.

After changing relevant sources, run:

```sh
python3 tools/check-integration-manifest.py --refresh
zig build test-m9p1
zig build test-m9p2
zig build test-m9p3
```

Also run the affected integration E2E tests; refreshing hashes is not compatibility validation. The manifest gate rejects stale digests, unsupported core versions, mismatched platform roots, oversized packages, and malformed artifact metadata. The compiler identity gate independently validates the actual dependency graph.

See [versioning](versioning.md) for compatibility policy. Release tooling builds the platform and integration bundles together and records URLs, versions, and hashes in release metadata.
