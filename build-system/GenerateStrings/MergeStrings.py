# MATTERMOST: merges a .strings overlay into a base .strings file (Relay's branding, Telegram/BUILD
# `RelayLocalizableStrings`). A key in the overlay replaces the base entry in place; new keys are appended.
# Comments and everything else in the base file are kept, so GenerateStrings.py parses the result as before.
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from GenerateStrings import _get_content, parse_strings  # noqa: E402
import re  # noqa: E402

# Same entry pattern as GenerateStrings.parse_strings.
_comment = r'(?:/\*(?P<comment>(?:[^*]|(?:\*+[^*/]))*\**)\*/)'
_entry = re.compile(r'(?:%s[ \t]*[\n]|[\r\n]|[\r])?(?P<line>(("(?P<key>[^"\\]*(?:\\.[^"\\]*)*)")|('
                    r'?P<property>\w+))\s*=\s*"(?P<value>[^"\\]*(?:\\.[^"\\]*)*)"\s*;)' % _comment, re.DOTALL | re.U)


def _entries(content):
    result = []
    for match in _entry.finditer(content):
        key = match.group('key') or match.group('property')
        result.append((key, match.start('line'), match.end('line'), match.group('line')))
    return result


def merge(base_path, overlay_path, output_path):
    base = _get_content(base_path).lstrip(u'\ufeff')
    overlay = _get_content(overlay_path).lstrip(u'\ufeff')

    overlay_lines = {}
    for key, _, _, line in _entries(overlay):
        overlay_lines[key] = line

    pieces = []
    position = 0
    replaced = set()
    for key, start, end, _ in _entries(base):
        if key in overlay_lines:
            pieces.append(base[position:start])
            # A key may appear more than once upstream; every occurrence gets the overlay value.
            pieces.append(overlay_lines[key])
            position = end
            replaced.add(key)
    pieces.append(base[position:])
    merged = ''.join(pieces)

    added = [line for key, line in overlay_lines.items() if key not in replaced]
    if added:
        if not merged.endswith('\n'):
            merged += '\n'
        merged += '\n// Relay\n' + '\n'.join(added) + '\n'

    with open(output_path, 'w', encoding='utf-8') as file:
        file.write(merged)

    # The result must parse to exactly the base keys plus the new ones.
    base_keys = {entry['key'] for entry in parse_strings(base_path)}
    merged_entries = parse_strings(output_path)
    merged_keys = {entry['key'] for entry in merged_entries}
    expected = base_keys | set(overlay_lines.keys())
    if merged_keys != expected:
        sys.exit('MergeStrings: unexpected key set after merge')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', required=True)
    parser.add_argument('--overlay', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    merge(args.base, args.overlay, args.output)
