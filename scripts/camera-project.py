"""Add the camera system extension to a generated copy of the Xcode project."""

import json
import os
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = root / "cuelens.xcodeproj" / "project.xcproj"
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
host = os.environ["CUELENS_HOST_ID_FOR_BUILD"]
extension = f"{host}.camera"
product = f"{extension}.systemextension"

# XCProject uses an OpenStep property list that also allows trailing commas.
project = json.loads(subprocess.check_output(
    ["plutil", "-convert", "json", "-o", "-", str(source)]
))
project["files"].append({
    "kind": "folder", "path": "CameraExtension", "target-membership": ["CueLensCamera"]
})
products = next(item for item in project["files"] if item.get("name") == "Products")
products["children"].append({
    "path": f"<PRODUCTS>/{product}", "id": "CB39160A17FF44D7A0539A22",
    "type": "wrapper.system-extension", "index": False,
    "target-membership": [{
        "build-phase": "cuelens/copy/Embed System Extensions", "header-preservation": "remove-on-copy"
    }]
})
app = next(target for target in project["targets"] if target["name"] == "cuelens")
app["dependencies"] = ["CueLensCamera"]
app["build-phases"].append({
    "kind": "copy", "name": "Embed System Extensions",
    "bundle-base-path": "build-products-directory", "relative-path": "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"
})
app["build-settings"].update({
    "PRODUCT_BUNDLE_IDENTIFIER": host,
    "CUELENS_HOST_IDENTIFIER": host,
    "CODE_SIGN_ENTITLEMENTS": "Config/CueLens-CameraHost.entitlements",
    "INFOPLIST_KEY_NSSystemExtensionUsageDescription":
        "CueLens can make its local camera preview available to a meeting app you select."
})
project["targets"].append({
    "name": "CueLensCamera",
    "id": "CB39160A17FF44D7A0539A21",
    "product": f"Products/{product}",
    "product-type": "system-extension",
    "build-phases": ["compile-sources", "frameworks", "resources"],
    "build-settings": {
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_ENTITLEMENTS": "Config/CueLens-CameraExtension.entitlements",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_APP_SANDBOX": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Config/CameraExtension-Info.plist",
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": extension,
        "PRODUCT_NAME": extension,
        "SKIP_INSTALL": "YES",
        "SWIFT_VERSION": "5.0",
        "CUELENS_HOST_IDENTIFIER": host,
    }
})
(destination / "project.xcproj").write_text(json.dumps(project, indent=2) + "\n")
