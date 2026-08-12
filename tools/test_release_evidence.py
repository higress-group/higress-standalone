import pathlib
import unittest
from release_evidence import derive_pins, evidence_hash, validate, verify_resolved_image


def evidence():
    labels = {platform: {"org.opencontainers.image.revision": "a" * 40, "io.higress.higress-source-commit": "a" * 40, "io.higress.plugin-snapshot-sha256": "b" * 64, "io.higress.gateway-version": "2.0.0"} for platform in ["linux/amd64", "linux/arm64"]}
    gateway_annotations = {platform: {"org.opencontainers.image.revision": "a" * 40, "io.higress.higress-source-commit": "a" * 40, "io.higress.plugin-snapshot-sha256": "b" * 64, "io.higress.gateway-version": "2.0.0"} for platform in labels}
    plugin = lambda ref, digest: {"ref": ref, "digest": "sha256:" + digest * 64, "platforms": ["linux/amd64", "linux/arm64"], "labelsByPlatform": labels}
    gateway = lambda ref, digest: {"ref": ref, "digest": "sha256:" + digest * 64, "platforms": ["linux/amd64", "linux/arm64"], "annotationsByPlatform": gateway_annotations}
    return {"schemaVersion": 1, "gatewayVersion": "2.0.0", "standaloneBaseCommit": "f" * 40, "higress": {"releaseId": 1, "tag": "v2.0.0", "commit": "a" * 40}, "snapshot": {"path": "plugins/release/snapshots/2.0.0.json", "sha256": "b" * 64}, "console": {"releaseId": 2, "tag": "v2.0.0", "commit": "c" * 40, "chartRef": "registry.example/charts/console:2.0.0", "chartDigest": "sha256:" + "d" * 64, "provenanceAssetId": 3, "provenanceAssetName": "plugin-release-provenance.json", "provenanceAssetSha256": "4" * 64}, "pluginServer": plugin("registry.example/higress/plugin-server:2.0.0", "e"), "gatewayImages": {"controller": gateway("registry.example/higress/controller:2.0.0", "1"), "pilot": gateway("registry.example/higress/pilot:2.0.0", "2"), "gateway": gateway("registry.example/higress/gateway:2.0.0", "3")}}


class EvidenceTest(unittest.TestCase):
    def test_hash_is_canonical_and_pins_are_exact(self):
        item = evidence()
        self.assertEqual(evidence_hash(item), evidence_hash(dict(reversed(list(item.items())))))
        self.assertEqual(derive_pins(item)["pluginServerDigest"], "sha256:" + "e" * 64)

    def test_rejects_missing_and_drifted_identity(self):
        item = evidence(); item["console"].pop("chartDigest")
        with self.assertRaisesRegex(ValueError, "Console"):
            validate(item)

    def test_rejects_extra_or_tampered_top_level_identity(self):
        item = evidence(); item["unexpected"] = "mutable"
        # Unknown input is rejected so future callers cannot smuggle a pin.
        with self.assertRaisesRegex(ValueError, "incomplete"):
            validate(item)
        item = evidence(); item["pluginServer"]["digest"] = "sha256:not-a-digest"
        with self.assertRaisesRegex(ValueError, "plugin-server"):
            validate(item)

    def test_hash_changes_when_key_or_platform_evidence_is_tampered(self):
        item = evidence(); original = evidence_hash(item)
        item["pluginServer"]["ref"] = "registry.example/higress/plugin-server:other"
        self.assertNotEqual(original, evidence_hash(item))

    def test_rejects_gateway_platform_mismatch(self):
        item = evidence(); item["gatewayImages"]["gateway"]["platforms"] = ["linux/amd64"]
        with self.assertRaisesRegex(ValueError, "gateway image"):
            validate(item)

    def test_live_image_resolution_rejects_label_and_platform_drift(self):
        expected = evidence()["gatewayImages"]["gateway"]
        verify_resolved_image(expected, dict(expected))
        bad = dict(expected); bad["platforms"] = ["linux/amd64"]
        with self.assertRaisesRegex(ValueError, "platform"):
            verify_resolved_image(expected, bad)
        bad = dict(expected); bad["annotationsByPlatform"] = {"linux/amd64": {}}
        with self.assertRaisesRegex(ValueError, "provenance"):
            verify_resolved_image(expected, bad)

    def test_release_receiver_pairs_oras_setup_metadata_with_pinned_cli(self):
        workflow = (pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/sync-higress-release.yaml").read_text(encoding="utf-8")
        self.assertNotIn("oras-project/setup-oras@ca28077386065e263c03428f4ae0c09024817c93", workflow)
        self.assertEqual(1, workflow.count("version: 1.2.3"))
        self.assertEqual(1, workflow.count("oras-project/setup-oras@8d34698a59f5ffe24821f0b48ab62a3de8b64b20 # v1.2.3\n        with:\n          version: 1.2.3"))


if __name__ == "__main__":
    unittest.main()
