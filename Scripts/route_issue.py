#!/usr/bin/env python3
"""Choose area labels for an issue opened from one of TUFF's issue forms.

GitHub renders each form answer under a `### <label>` heading. This reads the
"Area" answer and maps every selected option through .github/issue-routing.json.
The issue body is untrusted text: it only selects keys from that fixed table,
so nothing a reporter writes can become a label that is not listed there.

    ISSUE_BODY="$body" python3 Scripts/route_issue.py   # prints one label per line
"""
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
ROUTING = ROOT / '.github/issue-routing.json'


def load_routing(path=ROUTING):
    return json.loads(Path(path).read_text())


def answer(body, heading):
    """The text under `### heading`, up to the next heading."""
    lines = body.replace('\r\n', '\n').split('\n')
    collecting = False
    collected = []
    for line in lines:
        if line.startswith('### '):
            if collecting:
                break
            collecting = line[4:].strip() == heading
            continue
        if collecting:
            collected.append(line)
    return '\n'.join(collected).strip()


def labels_for(body, routing):
    selected = answer(body or '', 'Area')
    if not selected or selected == '_No response_':
        return []
    labels = []
    # A multiple-choice dropdown renders as "One, Two". Options can themselves
    # contain commas, so match whole known options rather than splitting.
    remaining = selected
    for option in sorted(routing['areas'], key=len, reverse=True):
        if option in remaining:
            remaining = remaining.replace(option, '')
            for label in routing['areas'][option]:
                if label in routing['labels'] and label not in labels:
                    labels.append(label)
    return sorted(labels)


def main():
    for label in labels_for(os.environ.get('ISSUE_BODY', ''), load_routing()):
        print(label)
    return 0


if __name__ == '__main__':
    sys.exit(main())
