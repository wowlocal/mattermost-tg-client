# MATTERMOST: merges a .strings overlay into a base .strings file (Relay's branding and translations, Telegram/BUILD
# `RelayLocalizableStrings` and `RelayLocalizableStrings_<lang>`; docs/design/localization.md). A key in the overlay
# replaces the base entry in place; new keys are appended. Comments and everything else in the base file are kept,
# so GenerateStrings.py parses the result as before.
#
# English (the base language): `--base` is upstream's en.lproj/Localizable.strings, `--overlay` Relay.strings.
#
# Another language: `--base` (a full translation of upstream's strings) and `--overlay` (`<lang>.lproj/Relay.strings`)
# are both optional. With `--english` (the merged English file) and `--english-overlay` (Relay.strings) the result
# is checked against English, because a key the app reads from a translation and English disagree on can crash or
# rebrand the app:
# - every key must exist in English (a plural form only needs its key's plural family there);
# - a value may only use the positional arguments (`%@`, `%1$@`, `%d`) English has for that key: the generated
#   accessors fill arguments by index, and an extra index reads past the arguments;
# - a translated base that has a key Relay overrides in English (e.g. "Telegram" → "Relay" texts) must have the
#   override translated in the language's overlay too, or the translation's Telegram wording would win.
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from GenerateStrings import _get_content, parse_strings, parse_positional_arguments  # noqa: E402
import re  # noqa: E402

# Same entry pattern as GenerateStrings.parse_strings.
_comment = r'(?:/\*(?P<comment>(?:[^*]|(?:\*+[^*/]))*\**)\*/)'
_entry = re.compile(r'(?:%s[ \t]*[\n]|[\r\n]|[\r])?(?P<line>(("(?P<key>[^"\\]*(?:\\.[^"\\]*)*)")|('
                    r'?P<property>\w+))\s*=\s*"(?P<value>[^"\\]*(?:\\.[^"\\]*)*)"\s*;)' % _comment, re.DOTALL | re.U)
_plural = re.compile(r'^(.*?)_(0|1|2|3_10|many|any)$', re.U)


def _entries(content):
    result = []
    for match in _entry.finditer(content):
        key = match.group('key') or match.group('property')
        result.append((key, match.start('line'), match.end('line'), match.group('line')))
    return result


def _read(path):
    if path is None:
        return ''
    return (_get_content(path) or '').lstrip(u'\ufeff')


def _parse(path):
    if path is None:
        return []
    return parse_strings(path) if _read(path).strip() else []


def merge(base_path, overlay_path, output_path):
    base = _read(base_path)
    overlay = _read(overlay_path)

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
        if merged and not merged.endswith('\n'):
            merged += '\n'
        merged += '\n// Relay\n' + '\n'.join(added) + '\n'

    with open(output_path, 'w', encoding='utf-8') as file:
        file.write(merged)

    # The result must parse to exactly the base keys plus the new ones.
    base_keys = {entry['key'] for entry in _parse(base_path)}
    merged_keys = {entry['key'] for entry in _parse(output_path)}
    expected = base_keys | set(overlay_lines.keys())
    if merged_keys != expected:
        sys.exit('MergeStrings: unexpected key set after merge')


def _argument_indices(value):
    # 0-based: `%@ %@` are 0 and 1 (implicit), `%2$@ %1$@` are 1 and 0, so a translation may reorder English's.
    result = set()
    for argument in parse_positional_arguments(value):
        explicit = re.search(r'%(\d+)\$', value) is not None
        result.add(argument.index - 1 if explicit else argument.index)
    return result


def check_translation(output_path, base_path, overlay_path, english_path, english_overlay_path, language):
    english = {entry['key']: entry['value'] for entry in _parse(english_path)}
    english_plural_families = {}
    for key, value in english.items():
        match = _plural.match(key)
        if match is not None:
            family = english_plural_families.setdefault(match.group(1), set())
            family |= _argument_indices(value)

    errors = []
    for entry in _parse(output_path):
        key, value = entry['key'], entry['value']
        if key in english:
            allowed = _argument_indices(english[key])
        else:
            match = _plural.match(key)
            if match is None or match.group(1) not in english_plural_families:
                errors.append('"%s": not an English key' % key)
                continue
            allowed = english_plural_families[match.group(1)]
        extra = _argument_indices(value) - allowed
        if extra:
            errors.append('"%s": uses argument(s) %s that English does not have' % (
                key, ', '.join(str(index + 1) for index in sorted(extra))))

    if base_path is not None and english_overlay_path is not None:
        base_keys = {entry['key'] for entry in _parse(base_path)}
        overlay_keys = {entry['key'] for entry in _parse(overlay_path)}
        for entry in _parse(english_overlay_path):
            key = entry['key']
            if key in base_keys and key not in overlay_keys:
                errors.append('"%s": Relay overrides it in English; translate the override in %s.lproj/Relay.strings'
                              % (key, language))

    if errors:
        sys.exit('MergeStrings (%s): %d problem(s):\n  %s' % (language, len(errors), '\n  '.join(errors)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base')
    parser.add_argument('--overlay')
    parser.add_argument('--output', required=True)
    parser.add_argument('--language', default='en')
    parser.add_argument('--english', help='the merged English strings (checks a translation against them)')
    parser.add_argument('--english-overlay', help="Relay's English overlay (overrides a translation must translate)")
    args = parser.parse_args()
    if args.base is None and args.overlay is None:
        sys.exit('MergeStrings: needs --base, --overlay or both')
    merge(args.base, args.overlay, args.output)
    if args.english is not None:
        check_translation(args.output, args.base, args.overlay, args.english, args.english_overlay, args.language)
