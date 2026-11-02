#!/usr/bin/env python3
"""Adds a release to the Sparkle appcast (newest first), keeping earlier items.

    scripts/appcast.py site/appcast.xml --version 23 --short 0.3.0 \
        --url https://github.com/joshuaramkissoon/aside/releases/download/v0.3.0/Aside-0.3.0.dmg \
        --signature <edSignature> --length <bytes> --min-system 15.2

Called by scripts/release.sh. Re-running for the same build number replaces that item.
"""
import argparse
import os
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def q(tag: str) -> str:
    return f"{{{SPARKLE}}}{tag}"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("path")
    p.add_argument("--version", required=True, help="CFBundleVersion (build number)")
    p.add_argument("--short", required=True, help="CFBundleShortVersionString")
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True)
    p.add_argument("--min-system", required=True)
    p.add_argument("--notes", default="", help="URL of the release notes")
    a = p.parse_args()
    if not a.signature or not a.length.isdigit():
        raise SystemExit("appcast: missing EdDSA signature or length from sign_update")

    if os.path.exists(a.path):
        rss = ET.parse(a.path).getroot()
        channel = rss.find("channel")
    else:
        rss = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Aside"
        ET.SubElement(channel, "link").text = "https://aside-mac.vercel.app"
        ET.SubElement(channel, "description").text = "Aside for Mac updates"
        ET.SubElement(channel, "language").text = "en"

    for old in channel.findall("item"):
        if old.findtext(q("version")) == a.version:
            channel.remove(old)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Aside {a.short}"
    ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
    ET.SubElement(item, q("version")).text = a.version
    ET.SubElement(item, q("shortVersionString")).text = a.short
    ET.SubElement(item, q("minimumSystemVersion")).text = a.min_system
    if a.notes:
        ET.SubElement(item, q("releaseNotesLink")).text = a.notes
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "length": a.length,
        "type": "application/octet-stream",
        q("edSignature"): a.signature,
    })
    first = next((i for i, el in enumerate(channel) if el.tag == "item"), len(channel))
    channel.insert(first, item)

    ET.indent(rss, space="  ")
    ET.ElementTree(rss).write(a.path, encoding="utf-8", xml_declaration=True)
    print(f"appcast: {a.short} (build {a.version}) -> {a.url}")


if __name__ == "__main__":
    main()
