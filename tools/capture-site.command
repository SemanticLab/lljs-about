#!/usr/bin/python3
"""Capture Linking Lost Jazz Shrines with the frontmost macOS Chrome profile."""

from collections import deque
from email import policy
from email.parser import BytesParser
from html.parser import HTMLParser
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit


SITE = "https://sites.google.com/weeksvillesociety.org/linking-lost-jazz-shrines"
HOME = SITE + "/home"

OPEN_TAB = '''
tell application "/Applications/Google Chrome.app"
    if (count of windows) is 0 then make new window
    set captureWindow to front window
    set captureTab to make new tab at end of tabs of captureWindow
    return (id of captureWindow as text) & " " & (id of captureTab as text)
end tell
'''

SAVE_PAGE = '''
on run argv
    set {windowID, tabID, pageURL, destination} to argv
    set archiveFile to POSIX file destination
    tell application "/Applications/Google Chrome.app"
        set captureTab to tab id (tabID as integer) of window id (windowID as integer)
        set URL of captureTab to pageURL
        repeat 300 times
            delay 1
            set actualURL to URL of captureTab
            if actualURL is pageURL or actualURL starts with (pageURL & "?") or actualURL starts with (pageURL & "#") then
                if not (loading of captureTab) then
                    delay 1
                    save captureTab in archiveFile as "single file"
                    return
                end if
            end if
        end repeat
        error "Chrome did not reach the requested page. Check access in the capture tab."
    end tell
end run
'''

CLOSE_TAB = '''
on run argv
    tell application "/Applications/Google Chrome.app"
        close (tab id ((item 2 of argv) as integer) of window id ((item 1 of argv) as integer))
    end tell
end run
'''


def chrome(script, *args):
    result = subprocess.run(
        ["/usr/bin/osascript", "-", *args], input=script,
        text=True, capture_output=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def site_link(current_url, href):
    target = urlsplit(urljoin(current_url, href.strip()))
    if target.hostname in {"google.com", "www.google.com"} and target.path == "/url":
        query = parse_qs(target.query)
        target = urlsplit((query.get("q") or query.get("url") or [""])[0])
    if target.scheme not in {"http", "https"} or target.hostname != "sites.google.com":
        return None
    path = target.path.rstrip("/")
    root = urlsplit(SITE).path
    if path == root:
        return HOME
    if path.startswith(root + "/"):
        return urlunsplit(("https", "sites.google.com", path, "", ""))
    return None


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag in {"a", "area"}:
            href = dict(attrs).get("href")
            if href:
                self.hrefs.append(href)


def read_capture(path, page_url):
    # Chrome writes the closing MIME boundary after all resources are saved.
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if path.is_file():
            data = path.read_bytes()
            if data.rstrip().endswith(b"--"):
                archive = BytesParser(policy=policy.default).parsebytes(data)
                boundary = archive.get_boundary()
                if boundary and data.rstrip().endswith(b"--" + boundary.encode() + b"--"):
                    break
        time.sleep(0.5)
    else:
        raise RuntimeError("Chrome did not finish writing " + str(path))

    for part in archive.walk():
        if part.get_content_type() != "text/html":
            continue
        if site_link(page_url, part.get("Content-Location", "")) != page_url:
            continue
        parser = Links()
        parser.feed(part.get_content())
        return [url for href in parser.hrefs if (url := site_link(page_url, href))]
    raise RuntimeError("The saved archive does not contain the requested page: " + page_url)


def main():
    print("Using the frontmost Chrome window. If Google prompts for sign-in,"
          " finish signing in within the new tab.", flush=True)
    window_id, tab_id = chrome(OPEN_TAB).split()
    folder = Path(tempfile.mkdtemp(prefix="lljs-chrome-"))
    print("Capture folder:", folder, flush=True)
    pending = deque([HOME])
    seen = {HOME}
    manifest = {}
    try:
        while pending:
            url = pending.popleft()
            filename = f"page-{len(manifest) + 1:03d}.mhtml"
            print("Saving", url, flush=True)
            chrome(SAVE_PAGE, window_id, tab_id, url, str(folder / filename))
            links = read_capture(folder / filename, url)
            manifest[url] = filename
            (folder / "pages.json").write_text(json.dumps(manifest, indent=2) + "\n")
            for link in links:
                if link not in seen:
                    pending.append(link)
                    seen.add(link)
    except (RuntimeError, KeyboardInterrupt):
        print("Capture stopped. Completed archives are in", folder, file=sys.stderr)
        raise
    else:
        chrome(CLOSE_TAB, window_id, tab_id)
    print(f"Saved {len(manifest)} page(s) with their loaded assets in {folder}")
    from unpack_capture import extract
    extract(folder, Path(__file__).resolve().parents[1], SITE, HOME, site_link)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        sys.exit(str(error))
