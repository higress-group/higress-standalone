#!/usr/bin/env python3
"""Render Standalone's duplicated release pins from immutable upstream inputs."""
import argparse
import json
import pathlib
import re
import sys


def set_value(text, key, value):
    output, count = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", key + "='" + value + "'", text, count=1)
    if count != 1:
        raise ValueError("missing " + key)
    return output


def render(root, data):
    required = ["gatewayVersion", "consoleVersion", "pluginServerVersion", "mcpServerVersion", "snapshotSha256", "idempotencyKey", "standaloneBaseCommit", "gatewayImages", "pluginServerRef", "pluginServerDigest"]
    if any(not data.get(key) for key in required):
        raise ValueError("immutable release input is incomplete")
    version = data["gatewayVersion"]
    gateway_images = data["gatewayImages"]
    image_refs = {
        "CONTROLLER_IMAGE": gateway_images["controller"]["ref"] + "@" + gateway_images["controller"]["digest"],
        "PILOT_IMAGE": gateway_images["pilot"]["ref"] + "@" + gateway_images["pilot"]["digest"],
        "GATEWAY_IMAGE": gateway_images["gateway"]["ref"] + "@" + gateway_images["gateway"]["digest"],
        "PLUGIN_SERVER_IMAGE": data["pluginServerRef"] + "@" + data["pluginServerDigest"],
    }
    dockerfile = root / "all-in-one/Dockerfile"
    contents = dockerfile.read_text()
    for key, value in {"CORE_VERSION": version, "CONSOLE_VERSION": data["consoleVersion"], "ENVOY_VERSION": version, "PLUGIN_SERVER_VERSION": data["pluginServerVersion"]}.items():
        contents, count = re.subn(r"(?m)^ARG " + key + r"=.*$", "ARG " + key + "=" + value, contents, count=1)
        if count != 1: raise ValueError("missing Dockerfile " + key)
    for key, value in image_refs.items():
        contents, count = re.subn(r"(?m)^ARG " + re.escape(key) + r"=.*$", "ARG " + key + "=" + value, contents, count=1)
        if count != 1: raise ValueError("missing Dockerfile " + key)
    dockerfile.write_text(contents)
    env = root / "compose/.env"
    contents = env.read_text()
    for key, value in {"HIGRESS_CONTROLLER_TAG": version, "HIGRESS_PILOT_TAG": version, "HIGRESS_GATEWAY_TAG": version, "HIGRESS_CONSOLE_TAG": data["consoleVersion"], "HIGRESS_PLUGIN_SERVER_TAG": data["pluginServerVersion"], "MCP_SERVER_WASM_URL": "http://plugin-server:8080/plugins/mcp-server/" + data["mcpServerVersion"] + "/plugin.wasm"}.items():
        contents = set_value(contents, key, value)
    for key, value in {"HIGRESS_CONTROLLER_IMAGE": image_refs["CONTROLLER_IMAGE"], "HIGRESS_PILOT_IMAGE": image_refs["PILOT_IMAGE"], "HIGRESS_GATEWAY_IMAGE": image_refs["GATEWAY_IMAGE"], "HIGRESS_PLUGIN_SERVER_IMAGE": image_refs["PLUGIN_SERVER_IMAGE"]}.items():
        contents = set_value(contents, key, value)
    env.write_text(contents)
    configure = root / "bin/configure.sh"
    contents = configure.read_text()
    contents, count = re.subn(r"(?m)^HIGRESS_PLUGIN_SERVER_TAG=.*$", "HIGRESS_PLUGIN_SERVER_TAG=${HIGRESS_PLUGIN_SERVER_TAG:-" + data["pluginServerVersion"] + "}", contents, count=1)
    if count != 1: raise ValueError("missing configure fallback")
    for key, value in {"HIGRESS_CONTROLLER_IMAGE": image_refs["CONTROLLER_IMAGE"], "HIGRESS_PILOT_IMAGE": image_refs["PILOT_IMAGE"], "HIGRESS_GATEWAY_IMAGE": image_refs["GATEWAY_IMAGE"], "HIGRESS_PLUGIN_SERVER_IMAGE": image_refs["PLUGIN_SERVER_IMAGE"]}.items():
        contents, count = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", key + "=${" + key + ":-" + value + "}", contents, count=1)
        if count != 1: raise ValueError("missing configure image fallback " + key)
    contents, count = re.subn(r"plugins/mcp-server/[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?/plugin\.wasm", "plugins/mcp-server/" + data["mcpServerVersion"] + "/plugin.wasm", contents)
    if count != 1: raise ValueError("missing unique configure MCP pin")
    configure.write_text(contents)
    controller = root / "all-in-one/scripts/start-controller.sh"
    contents, count = re.subn(r"plugins/mcp-server/[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?/plugin\.wasm", "plugins/mcp-server/" + data["mcpServerVersion"] + "/plugin.wasm", controller.read_text())
    if count != 1: raise ValueError("missing unique controller MCP pin")
    controller.write_text(contents)
    (root / "release-provenance.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--root", default="."); parser.add_argument("--input", required=True); args = parser.parse_args()
    try: render(pathlib.Path(args.root), json.loads(pathlib.Path(args.input).read_text()))
    except (OSError, ValueError, json.JSONDecodeError) as error: print("release pin render failed: " + str(error), file=sys.stderr); return 1
    return 0


if __name__ == "__main__": sys.exit(main())
