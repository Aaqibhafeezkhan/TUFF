#!/usr/bin/env python3
"""Add TUFF data-format and recovery declarations before signing an appcast."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

NAMESPACE = 'https://github.com/rexmhall09/TUFF/appcast'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
ET.register_namespace('tuff', NAMESPACE)
CURRENT_FORMATS = {'chats': 2, 'app_settings': 7, 'background_settings': 1}
ELEMENTS = {'chats': 'chatsSchema', 'app_settings': 'appSettingsVersion',
            'background_settings': 'backgroundSettingsVersion'}


def stamp(path, provenance=None):
    tree = ET.parse(path)
    items = tree.getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('expected a feed containing exactly one candidate')
    item = items[0]
    formats = provenance['data_formats'] if provenance else CURRENT_FORMATS
    for key, name in ELEMENTS.items():
        value = formats[key]
        if type(value) is not int or value < 1:
            raise ValueError('data-format versions must be positive integers')
        existing = item.find(f'{{{NAMESPACE}}}{name}')
        if existing is None:
            existing = ET.SubElement(item, f'{{{NAMESPACE}}}{name}')
        existing.text = str(value)
    if provenance:
        version = item.findtext(f'{{{SPARKLE}}}version')
        if version != provenance['recovery_version']:
            raise ValueError('provenance does not match the packaged version')
        for key, value in {'recovery': 'true', 'withdrawnVersion': provenance['withdrawn_version'],
                           'knownGoodCommit': provenance['known_good_commit']}.items():
            ET.SubElement(item, f'{{{NAMESPACE}}}{key}').text = value
    tree.write(path, encoding='utf-8', xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appcast', type=Path)
    parser.add_argument('--recovery-provenance', type=Path)
    args = parser.parse_args()
    stamp(args.appcast, json.loads(args.recovery_provenance.read_text()) if args.recovery_provenance else None)


if __name__ == '__main__':
    main()
