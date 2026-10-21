# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3==1.43.112"]
# ///
"""Publish pinned Mac model files and HF-compatible listings to R2.

Ported from DaisyLite (iPhone), 2026-10-21, backlog 31: the same bucket and
layout. The Mac's sources are a superset of the iPhone's for the repositories
they share (same pinned revisions), so the discovery listings it publishes
never drop a file the iPhone serves; its manifest goes to its own key.

Credentials come only from the local Keychain record created by
store-r2-credentials.command. No secrets are accepted as arguments or logged.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Docs/models-sources.json"
MANIFEST = ROOT / "Daisy/ModelsManifest.json"
CACHE = ROOT / "build/model-hosting/cache"
MIRROR = "https://models.mydaisy.io"
HF = "https://huggingface.co"


def safe_path(value):
    if (not isinstance(value, str) or not value or value.startswith("/")
            or any(x in ("", ".", "..") for x in value.split("/"))
            or "\\" in value or any(ord(c) < 32 for c in value)):
        raise ValueError("Invalid relative model path")
    return value


def configuration():
    data = json.loads(SOURCES.read_text())
    assert data["schemaVersion"] == 1
    seen = set()
    for repo in data["repositories"]:
        name = safe_path(repo["repo"])
        if len(name.split("/")) != 2 or name in seen:
            raise ValueError("Duplicate or invalid repository")
        seen.add(name)
        if not re.fullmatch(r"[0-9a-f]{40}", repo["revision"]):
            raise ValueError("Every source must pin a full HF commit")
        for path in repo["required"]:
            safe_path(path)
    return data


def request_json(url):
    with urlopen(Request(url, headers={"User-Agent": "Daisy-models-sync/1"}), timeout=45) as response:
        return json.load(response), response.headers.get("Link", "")


def tree(source):
    repo, revision = source["repo"], source["revision"]
    prefix = f"{HF}/api/models/{repo}/tree/{revision}"
    required = source["required"]
    licenses = {"LICENSE", "LICENSE.md", "LICENSE.txt", "NOTICE.md", "README.md"}
    files = []

    def selected(path):
        return path in licenses or any(path == r or path.startswith(r + "/") for r in required)

    def walk(directory="", depth=0):
        if depth > 32:
            raise ValueError("Model tree is too deep")
        url = prefix + ("/" + quote(directory, safe="/") if directory else "")
        visited = set()
        while url:
            if url in visited or not (url == prefix or url.startswith(prefix + "/") or url.startswith(prefix + "?")):
                raise ValueError("Unsafe or repeated tree pagination")
            visited.add(url)
            items, link = request_json(url)
            if not isinstance(items, list):
                raise ValueError("Unexpected HF tree response")
            for item in items:
                path = safe_path(item["path"])
                if str(PurePosixPath(path).parent) != (directory or "."):
                    raise ValueError("HF tree item escaped its directory")
                if not selected(path):
                    continue
                if item["type"] == "directory":
                    walk(path, depth + 1)
                elif item["type"] == "file":
                    size = item["size"]
                    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                        raise ValueError("Invalid source file size")
                    lfs = item.get("lfs", {}).get("oid")
                    oid = item.get("oid")
                    if lfs is not None and not re.fullmatch(r"[0-9a-f]{64}", lfs):
                        raise ValueError("Invalid LFS digest")
                    if lfs is None and not re.fullmatch(r"[0-9a-f]{40}", oid or ""):
                        raise ValueError("File has no verifiable upstream digest")
                    files.append({"repo": repo, "revision": revision, "path": path,
                                  "size": size, "upstreamSHA256": lfs,
                                  "gitBlobSHA1": oid if lfs is None else None,
                                  "runtime": any(path == r or path.startswith(r + "/") for r in required)})
                else:
                    raise ValueError("Unexpected HF tree item type")
            next_pages = re.findall(r'<([^>]+)>;\s*rel="?next"?', link)
            url = next_pages[0] if next_pages else None

    walk()
    for required_path in required:
        if not any(f["path"] == required_path or f["path"].startswith(required_path + "/") for f in files):
            raise ValueError("A required model is missing from the pinned revision")
    if len({f["path"] for f in files}) != len(files):
        raise ValueError("Duplicate file in source tree")
    return sorted(files, key=lambda f: f["path"])


def digest(path):
    size = path.stat().st_size
    sha256 = hashlib.sha256()
    blob = hashlib.sha1(f"blob {size}\0".encode())
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha256.update(chunk)
            blob.update(chunk)
    return size, sha256.hexdigest(), blob.hexdigest()


def local_path(entry):
    return CACHE / safe_path(entry["repo"]) / entry["revision"] / safe_path(entry["path"])


def validate_file(path, entry):
    size, sha256, blob = digest(path)
    if size != entry["size"]:
        raise ValueError("Model size mismatch")
    if entry.get("sha256") and sha256 != entry["sha256"]:
        raise ValueError("Model SHA-256 mismatch")
    if entry.get("upstreamSHA256") and sha256 != entry["upstreamSHA256"]:
        raise ValueError("Upstream LFS SHA-256 mismatch")
    if entry.get("gitBlobSHA1") and blob != entry["gitBlobSHA1"]:
        raise ValueError("Upstream git blob digest mismatch")
    return sha256


def download(entry):
    path = local_path(entry)
    if path.exists():
        try:
            return {**entry, "sha256": validate_file(path, entry)}
        except ValueError:
            pass  # Refetch a corrupt cache entry into a separate temporary file.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    url = f'{HF}/{entry["repo"]}/resolve/{entry["revision"]}/{quote(entry["path"], safe="/")}'
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers={"User-Agent": "Daisy-models-sync/1"}), timeout=60) as response, temporary.open("wb") as out:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    out.write(chunk)
                    if out.tell() > entry["size"]:
                        raise ValueError("Download exceeded pinned file size")
            sha256 = validate_file(temporary, entry)
            temporary.replace(path)
            print(f'Downloaded {entry["repo"]}/{entry["path"]}: {entry["size"]} B sha256={sha256}', flush=True)
            return {**entry, "sha256": sha256}
        except (HTTPError, URLError, TimeoutError, OSError):
            if attempt == 2:
                raise
            time.sleep(1 + attempt)
        finally:
            temporary.unlink(missing_ok=True)


def write_inventory(manifest):
    lines = ["# Mac model inventory", "", "Generated by `scripts/models-sync.sh prepare` from `Docs/models-sources.json`.",
             "Every file is downloaded from a pinned HF commit and verified against its upstream LFS SHA-256 or git blob SHA-1 before recording SHA-256.",
             "", "This inventory covers the models Daisy for Mac downloads: both Whisper large-v3 variants and their tokenizer, Parakeet TDT 0.6B v3, Silero VAD and the legacy speaker models. Nemotron (live preview, off by default) still comes from Hugging Face through FluidAudio. The iPhone's inventory is in DaisyLite `Docs/models.md` (same revisions for the shared repositories).",
             "", "Revisions: Whisper, tokenizer and speaker models as DaisyLite (2026-10-13); Parakeet v3 and Silero VAD resolved on 2026-10-21.",
             "", "Runtime paths: `MacModelHosting` pre-fetches into the WhisperKit and FluidAudio caches (`WhisperEngine`, `ParakeetEngine`, `DiarizationEngine`); the libraries' own Hugging Face download is the last fallback.",
             "", "Mirror: `https://models.mydaisy.io/<owner>/<repo>/resolve/main/<path>`. Upstream fallback must use the pinned commit from the manifest.",
             "", "Keychain: service `io.mydaisy.models.r2`, account `daisy-models`; credentials never belong in this document.", ""]
    for source in manifest["repositories"]:
        lines += [f'## {source["repo"]}', "", f'Purpose: {source["purpose"]}. Authors: {source["authors"]}.',
                  f'License: {source["license"]}. Revision: `{source["revision"]}`.', "",
                  "| File | Bytes | SHA-256 | Runtime |", "|---|---:|---|---|"]
        for f in manifest["files"]:
            if f["repo"] == source["repo"]:
                lines.append(f'| `{f["path"]}` | {f["size"]} | `{f["sha256"]}` | {"yes" if f["runtime"] else "license / documentation"} |')
        lines.append("")
    atomic_write(ROOT / "Docs/models.md", "\n".join(lines).encode())


def atomic_write(path, body):
    temporary = path.with_name(path.name + ".tmp")
    try:
        temporary.write_bytes(body)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare():
    sources = configuration()
    entries = []
    for source in sources["repositories"]:
        entries.extend(tree(source))
    with ThreadPoolExecutor(max_workers=4) as executor:
        files = list(executor.map(download, entries))
    manifest = {"schemaVersion": 1, "repositories": sources["repositories"], "files": files}
    atomic_write(MANIFEST, (json.dumps(manifest, indent=2) + "\n").encode())
    write_inventory(manifest)
    print(f'Prepared {len(files)} files, {sum(f["size"] for f in files)} bytes. No R2 objects changed.')


def load_manifest():
    manifest = json.loads(MANIFEST.read_text())
    if manifest["schemaVersion"] != 1 or manifest["repositories"] != configuration()["repositories"]:
        raise ValueError("Manifest does not match the pinned sources; run prepare")
    repos = {r["repo"]: r for r in manifest["repositories"]}
    seen = set()
    for f in manifest["files"]:
        safe_path(f["path"])
        identity = (f["repo"], f["path"])
        if identity in seen or f["revision"] != repos[f["repo"]]["revision"]:
            raise ValueError("Duplicate file or revision mismatch")
        seen.add(identity)
        if not re.fullmatch(r"[0-9a-f]{64}", f["sha256"]):
            raise ValueError("Invalid pinned SHA-256")
    if not seen:
        raise ValueError("Empty manifest")
    return manifest


def api_listings(manifest):
    objects = {}
    for source in manifest["repositories"]:
        repo = source["repo"]
        files = [f for f in manifest["files"] if f["repo"] == repo]
        directories = {"": {}}
        for f in files:
            parts = f["path"].split("/")
            for i in range(1, len(parts)):
                directory = "/".join(parts[:i])
                parent = "/".join(parts[:i-1])
                directories.setdefault(parent, {})[directory] = {"type": "directory", "path": directory}
                directories.setdefault(directory, {})
            parent = "/".join(parts[:-1])
            # The compatibility API supplies SHA-256 for small files too.
            directories[parent][f["path"]] = {"type": "file", "path": f["path"], "size": f["size"],
                                                "lfs": {"oid": f["sha256"], "size": f["size"]}}
        for directory, items in directories.items():
            key = f"api/models/{repo}/tree/main" + ("/" + directory if directory else "")
            objects[key] = json.dumps(sorted(items.values(), key=lambda x: x["path"]), separators=(",", ":")).encode()
        objects[f"api/models/{repo}"] = json.dumps({"id": repo, "sha": source["revision"],
                                                  "siblings": [{"rfilename": f["path"]} for f in files]}).encode()
    return objects


def r2_client():
    import boto3
    from botocore.config import Config
    result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "io.mydaisy.models.r2",
                             "-a", "daisy-models", "-w"], capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError("Keychain credentials unavailable (unlock/allow access locally)")
    credentials = json.loads(result.stdout)
    if (credentials["bucket"] != "daisy-models" or
        not re.fullmatch(r"https://[0-9a-f]{32}\.eu\.r2\.cloudflarestorage\.com", credentials["endpoint"])):
        raise ValueError("Keychain bucket or EU endpoint invalid")
    client = boto3.client("s3", endpoint_url=credentials["endpoint"], region_name="auto",
                          aws_access_key_id=credentials["accessKeyID"], aws_secret_access_key=credentials["secretAccessKey"],
                          config=Config(signature_version="s3v4", s3={"addressing_style": "path"},
                                        connect_timeout=10, read_timeout=30,
                                        request_checksum_calculation="when_required", response_checksum_validation="when_required",
                                        retries={"max_attempts": 3, "mode": "standard"}))
    return client


def upload():
    manifest = load_manifest()
    # Verify ALL files before the first remote write.
    for f in manifest["files"]:
        validate_file(local_path(f), f)
    client = r2_client()
    bucket = "daisy-models"
    uploaded = []
    for f in manifest["files"]:
        key = f'{f["repo"]}/resolve/main/{f["path"]}'
        metadata = {"sha256": f["sha256"], "hf-revision": f["revision"]}
        if already_stored(client, bucket, key, f):
            print(f'Already stored, same SHA-256: {key}', flush=True)
            continue
        uploaded.append(f)
        client.upload_file(str(local_path(f)), bucket, key,
                           ExtraArgs={"Metadata": metadata, "CacheControl": "public, max-age=3600",
                                      "ContentType": "application/json" if f["path"].endswith(".json") else "application/octet-stream"})
        print(f'Uploaded {key}: sha256={f["sha256"]}', flush=True)
    # The metadata is what this script wrote; it proves nothing about the
    # stored bytes (audit 2026-10-17). Read every object back and hash it.
    # Objects already there were verified when the iPhone's run put them
    # there; verify-public re-reads every one through the CDN anyway.
    for f in uploaded:
        verify_stored(client, bucket, f'{f["repo"]}/resolve/main/{f["path"]}', f)
    # Publish discovery only AFTER every verified file is present.
    objects = api_listings(manifest)
    objects["daisy/mac-models-manifest-v1.json"] = MANIFEST.read_bytes()
    for key, body in objects.items():
        client.put_object(Bucket=bucket, Key=key, Body=body, ContentType="application/json",
                          CacheControl="public, max-age=300", Metadata={"sha256": hashlib.sha256(body).hexdigest()})
    print(f'Published {len(manifest["files"])} model/license files and {len(objects)} discovery objects. No objects deleted.')


def already_stored(client, bucket, key, f):
    """The object is there with this size and the SHA-256 our upload wrote."""
    try:
        head = client.head_object(Bucket=bucket, Key=key)
    except Exception as error:
        code = getattr(error, "response", {}).get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NotFound"):
            return False
        raise
    return head.get("ContentLength") == f["size"] and head.get("Metadata", {}).get("sha256") == f["sha256"]


def verify_stored(client, bucket, key, f):
    """Stream the object as R2 stores it and compare size and SHA-256."""
    body = client.get_object(Bucket=bucket, Key=key)["Body"]
    sha256 = hashlib.sha256()
    size = 0
    for chunk in iter(lambda: body.read(1024 * 1024), b""):
        sha256.update(chunk)
        size += len(chunk)
        if size > f["size"]:
            raise ValueError(f"R2 object larger than pinned: {key}")
    if size != f["size"] or sha256.hexdigest() != f["sha256"]:
        raise ValueError(f"R2 object checksum mismatch: {key}")
    print(f'Stored SHA-256 OK: {key}', flush=True)


def verify_public():
    manifest = load_manifest()
    def check(f):
        url = f'{MIRROR}/{f["repo"]}/resolve/main/{quote(f["path"], safe="/")}'
        sha256 = hashlib.sha256()
        size = 0
        request = Request(url, headers={"User-Agent": "Daisy-models-sync/1"})
        with urlopen(request, timeout=60) as response:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                sha256.update(chunk)
                size += len(chunk)
                if size > f["size"]:
                    raise ValueError("Public model exceeded pinned size")
        if size != f["size"] or sha256.hexdigest() != f["sha256"]:
            raise ValueError("Public model checksum mismatch")
        print(f'Public SHA-256 OK: {f["repo"]}/{f["path"]}', flush=True)
    with ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(check, manifest["files"]))
    for key, expected in api_listings(manifest).items():
        actual, _ = request_json(f"{MIRROR}/{key}")
        if actual != json.loads(expected):
            raise ValueError("Public discovery listing mismatch")
    print("Public mirror: all files and discovery listings verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "upload", "check", "verify-public", "manifest"])
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "upload":
        upload()
    elif args.command == "verify-public":
        verify_public()
    elif args.command == "manifest":
        manifest = load_manifest()
        for f in manifest["files"]:
            validate_file(local_path(f), f)
        print(json.dumps(manifest, indent=2))
    elif args.command == "check":
        r2_client().list_objects_v2(Bucket="daisy-models", MaxKeys=1)
        print("R2 authentication OK; EU bucket daisy-models accessible. No objects changed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # SDK errors are reduced to an error code; never dump requests/credentials.
        response = getattr(error, "response", {})
        if isinstance(response, dict) and "Error" in response:
            message = response["Error"].get("Code", "S3Error")
        elif isinstance(error, FileNotFoundError):
            message = "Required local model/cache file is missing; run prepare"
        elif isinstance(error, ValueError):
            message = str(error)
        else:
            message = type(error).__name__
        print("Model hosting failed: " + message, file=sys.stderr)
        sys.exit(1)
