#!/usr/bin/env python3
"""Canonical immutable Higress release evidence helpers for Standalone.

The workflow performs remote lookups; this module owns the strict shape,
canonical JSON hashing, and the only mapping from verified evidence to local
release pins. Keeping that mapping here prevents a dispatch payload from
silently selecting a different tag or mutable image.
"""
import hashlib
import json
import re


SHA = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def evidence_hash(value):
    validate(value)
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def validate(value):
    required = {"schemaVersion", "gatewayVersion", "higress", "snapshot", "console", "pluginServer", "gatewayImages", "standaloneBaseCommit"}
    if not isinstance(value, dict) or set(value) != required or value["schemaVersion"] != 1:
        raise ValueError("unsupported or incomplete release evidence schema")
    if not VERSION.fullmatch(value["gatewayVersion"]):
        raise ValueError("gatewayVersion is not stable SemVer")
    h, snapshot, console, plugin = value["higress"], value["snapshot"], value["console"], value["pluginServer"]
    if not COMMIT.fullmatch(value["standaloneBaseCommit"]):
        raise ValueError("Standalone base commit is incomplete")
    if not isinstance(h.get("releaseId"), int) or not re.fullmatch(r"v" + VERSION.pattern[1:-1], h.get("tag", "")) or not COMMIT.fullmatch(h.get("commit", "")):
        raise ValueError("Higress release identity is incomplete")
    if not snapshot.get("path", "").startswith("plugins/release/snapshots/") or not SHA.fullmatch(snapshot.get("sha256", "")):
        raise ValueError("snapshot identity is incomplete")
    chart_digest = console.get("chartDigest", "")
    plugin_digest = plugin.get("digest", "")
    if chart_digest.startswith("sha256:"):
        chart_digest = chart_digest[7:]
    if plugin_digest.startswith("sha256:"):
        plugin_digest = plugin_digest[7:]
    asset_digest = console.get("provenanceAssetSha256", "")
    if not isinstance(console.get("releaseId"), int) or not COMMIT.fullmatch(console.get("commit", "")) or not SHA.fullmatch(chart_digest) or not console.get("chartRef") or not isinstance(console.get("provenanceAssetId"), int) or console.get("provenanceAssetName") != "plugin-release-provenance.json" or not SHA.fullmatch(asset_digest):
        raise ValueError("Console release/chart identity is incomplete")
    if not plugin.get("ref") or not SHA.fullmatch(plugin_digest):
        raise ValueError("plugin-server identity is incomplete")
    required_plugin_labels = {"org.opencontainers.image.revision", "io.higress.higress-source-commit", "io.higress.plugin-snapshot-sha256", "io.higress.gateway-version"}
    plugin_labels = plugin.get("labelsByPlatform", {})
    if plugin.get("platforms") != ["linux/amd64", "linux/arm64"] or set(plugin_labels) != {"linux/amd64", "linux/arm64"} or any(not required_plugin_labels.issubset(item) for item in plugin_labels.values()):
        raise ValueError("plugin-server platform/label evidence is incomplete")
    images = value["gatewayImages"]
    if not isinstance(images, dict) or set(images) != {"controller", "pilot", "gateway"}:
        raise ValueError("gateway image evidence is incomplete")
    for name, image in images.items():
        digest = image.get("digest", "")
        annotations = image.get("annotationsByPlatform", {})
        required_labels = {"org.opencontainers.image.revision", "io.higress.higress-source-commit", "io.higress.plugin-snapshot-sha256", "io.higress.gateway-version"}
        if not image.get("ref") or not SHA.fullmatch(digest[7:] if digest.startswith("sha256:") else "") or image.get("platforms") != ["linux/amd64", "linux/arm64"] or set(annotations) != {"linux/amd64", "linux/arm64"} or any(not required_labels.issubset(item) for item in annotations.values()):
            raise ValueError("gateway image %s identity/platform/annotations are incomplete" % name)


def derive_pins(value):
    """Return only pins that are allowed to flow into render_release_pins."""
    validate(value)
    return {
        "gatewayVersion": value["gatewayVersion"],
        "higressCommit": value["higress"]["commit"],
        "snapshotSha256": value["snapshot"]["sha256"],
        "consoleChartRef": value["console"]["chartRef"],
        "consoleChartDigest": value["console"]["chartDigest"],
        "pluginServerRef": value["pluginServer"]["ref"],
        "pluginServerDigest": value["pluginServer"]["digest"],
        "gatewayImages": value["gatewayImages"],
        "standaloneBaseCommit": value["standaloneBaseCommit"],
    }


def verify_resolved_image(expected, resolved):
    """Fail closed on the descriptor/platform/label data returned by ORAS.

    Workflows collect this live data, then pass it through this pure helper so
    tests cover the boundary instead of relying on fragile shell comparisons.
    """
    if expected["digest"] != resolved.get("digest"):
        raise ValueError("resolved image digest differs from canonical evidence")
    if expected["platforms"] != sorted(resolved.get("platforms", [])):
        raise ValueError("resolved image platform set differs from canonical evidence")
    location = "annotationsByPlatform" if "annotationsByPlatform" in expected else "labelsByPlatform"
    if expected.get(location) != resolved.get(location):
        raise ValueError("resolved image provenance differs from canonical evidence")
