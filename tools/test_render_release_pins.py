import importlib.util, json, pathlib, shutil, tempfile, unittest
ROOT = pathlib.Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("renderer", ROOT / "tools/render_release_pins.py")
renderer = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(renderer)
DATA = {"gatewayVersion":"2.3.0","consoleVersion":"2.3.1","pluginServerVersion":"2.3.0","mcpServerVersion":"2.4.0","snapshotSha256":"a"*64,"idempotencyKey":"release-2.3.0-a","standaloneBaseCommit":"b"*40,"gatewayImages":{"controller":{"ref":"registry/controller:2.3.0","digest":"sha256:" + "c"*64},"pilot":{"ref":"registry/pilot:2.3.0","digest":"sha256:" + "d"*64},"gateway":{"ref":"registry/gateway:2.3.0","digest":"sha256:" + "e"*64}},"pluginServerRef":"registry/plugin-server:2.3.0","pluginServerDigest":"sha256:" + "f"*64}
class TestRender(unittest.TestCase):
 def test_all_authorities_and_repeat(self):
  with tempfile.TemporaryDirectory() as temp:
   work=pathlib.Path(temp)/"repo"; shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git"))
   renderer.render(work, DATA); renderer.render(work, DATA)
   self.assertIn("mcp-server/2.4.0", (work/"compose/.env").read_text())
   self.assertIn("mcp-server/2.4.0", (work/"bin/configure.sh").read_text())
   self.assertIn("mcp-server/2.4.0", (work/"all-in-one/scripts/start-controller.sh").read_text())
   self.assertIn("HIGRESS_PLUGIN_SERVER_TAG=${HIGRESS_PLUGIN_SERVER_TAG:-2.3.0}", (work/"bin/configure.sh").read_text())
   controller = "registry/controller:2.3.0@sha256:" + "c" * 64
   pilot = "registry/pilot:2.3.0@sha256:" + "d" * 64
   gateway = "registry/gateway:2.3.0@sha256:" + "e" * 64
   plugin_server = "registry/plugin-server:2.3.0@sha256:" + "f" * 64
   dockerfile = (work / "all-in-one/Dockerfile").read_text()
   compose_env = (work / "compose/.env").read_text()
   configure = (work / "bin/configure.sh").read_text()
   compose = (work / "compose/docker-compose.yml").read_text()
   for image in (controller, pilot, gateway, plugin_server):
    self.assertIn(image, dockerfile)
    self.assertIn(image, compose_env)
    self.assertIn(image, configure)
   self.assertIn("image: ${HIGRESS_CONTROLLER_IMAGE}", compose)
   self.assertIn("image: ${HIGRESS_PLUGIN_SERVER_IMAGE}", compose)
   upgraded = dict(DATA, mcpServerVersion="2.5.0")
   renderer.render(work, upgraded)
   self.assertIn("mcp-server/2.5.0", (work/"bin/configure.sh").read_text())
   self.assertIn("mcp-server/2.5.0", (work/"all-in-one/scripts/start-controller.sh").read_text())
if __name__ == "__main__": unittest.main()
