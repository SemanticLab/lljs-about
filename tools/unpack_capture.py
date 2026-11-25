"""Turn Chrome MHTML captures into ordinary files with relative URLs."""

from email import policy
from email.parser import BytesParser
from hashlib import sha256
from pathlib import Path
import json
import mimetypes
import os
import re
import shutil
from urllib.parse import quote, unquote, urldefrag, urljoin, urlsplit

from lxml import etree, html


CSS_URL = re.compile(r'''(?i)(url\(\s*|@import\s+)(["']?)([^"')\s]+)\2''')


def page_path(url, site, home):
    if url == home:
        return Path("index.html")
    segments = [unquote(segment) for segment in url[len(site) + 1:].split("/")]
    if any(s in {"", ".", ".."} or "/" in s or "\\" in s for s in segments):
        raise ValueError("Unexpected page path: " + url)
    return Path(*segments, "index.html")


def extract(folder, project, site, home, site_link):
    manifest = json.loads((folder / "pages.json").read_text())
    pages = {url: page_path(url, site, home) for url in manifest}
    output = folder / "static"
    output.mkdir(exist_ok=True)
    for page_url, archive_name in manifest.items():
        archive = BytesParser(policy=policy.default).parsebytes((folder / archive_name).read_bytes())
        files = {}
        parts = []
        for part in archive.walk():
            if part.is_multipart():
                continue
            mime = part.get_content_type()
            data = part.get_payload(decode=True)
            location = str(part.get("Content-Location", "")).strip()
            cid = str(part.get("Content-ID", "")).strip().strip("<>")
            aliases = ([urljoin(page_url, location)] if location else []) + (["cid:" + cid] if cid else [])
            if not aliases:
                continue
            if mime == "text/html" and location and site_link(page_url, location) == page_url:
                dest = pages[page_url]
            else:
                # CSS and frames may use relative references specific to this capture.
                context = (page_url + "\n" + location).encode() if mime in {"text/html", "text/css"} else b""
                suffix = mimetypes.guess_extension(mime) or ".bin"
                dest = Path("assets", sha256(context + data).hexdigest()[:24] + suffix)
            files.update(dict.fromkeys(aliases, dest))
            parts.append((part, data, dest, location))

        for part, data, dest, location in parts:
            target = output / dest
            if target.exists():
                continue
            target.parent.mkdir(exist_ok=True, parents=True)
            base = urljoin(page_url, location) if location and not location.startswith("cid:") else page_url

            def rewrite(value):
                if not value or value.startswith(("#", "data:", "mailto:", "tel:", "javascript:")):
                    return value
                absolute, fragment = urldefrag(urljoin(base, value))
                path = files.get(absolute) or pages.get(site_link(page_url, absolute))
                if path is None:
                    return urljoin(base, value)
                relative = quote(os.path.relpath(path, dest.parent), safe="/")
                return relative + ("#" + fragment if fragment else "")

            def css(value):
                return CSS_URL.sub(lambda m: m[1] + '"' + rewrite(m[3]) + '"', value)

            mime = part.get_content_type()
            if mime == "text/html":
                encoding = part.get_content_charset() or "utf-8"
                doc = html.document_fromstring(data.decode(encoding, errors="replace"))
                for element in doc.xpath("//base[@href]"):
                    base = urljoin(base, element.get("href"))
                    element.attrib.pop("href")
                for element in doc.iter(etree.Element):
                    for attr in ("href", "src", "poster", "background", "{http://www.w3.org/1999/xlink}href"):
                        if attr in element.attrib:
                            element.set(attr, rewrite(element.get(attr)))
                    if element.tag == "object" and "data" in element.attrib:
                        element.set("data", rewrite(element.get("data")))
                    if "srcset" in element.attrib:
                        # Chromium embeds the selected image in the saved page.
                        element.set("srcset", re.sub(r"(?:https?://|cid:)[^,\s]+",
                                                      lambda m: rewrite(m[0]), element.get("srcset")))
                    if "style" in element.attrib:
                        element.set("style", css(element.get("style")))
                    if element.tag == "style" and element.text:
                        element.text = css(element.text)
                data = html.tostring(doc, encoding="utf-8", include_meta_content_type=True,
                                     doctype="<!doctype html>")
            elif mime == "text/css":
                data = css(data.decode(part.get_content_charset() or "utf-8", errors="replace")).encode()
            target.write_bytes(data)

    for path in pages.values():
        if not (output / path).is_file():
            raise ValueError("Missing captured page: " + str(path))
    (output / ".nojekyll").touch()
    entries = [entry for entry in output.iterdir() if entry.name != ".nojekyll"]
    if any((project / entry.name).exists() for entry in entries):
        print("Existing project files preserved. The new static copy is in", output)
        return
    for entry in entries:
        if entry.is_dir():
            shutil.copytree(entry, project / entry.name)
        else:
            shutil.copy2(entry, project / entry.name)
    (project / ".nojekyll").touch()
    print("Static HTML and assets are in", project)
