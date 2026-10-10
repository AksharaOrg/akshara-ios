#!/usr/bin/env python3
"""Pair simulator timing signposts; no text or touch data is collected.

The timebase must match the machine that recorded the simulator run.
Example for the archived run:
  python3 Scripts/analyze_keyboard_signposts.py \
    Docs/Performance/Simulator-2026-10-11/signposts.ndjson.gz \
    --timebase-numer 125 --timebase-denom 3 --output /tmp/intervals.json
"""
import argparse
import collections
import gzip
import json
import math
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('input')
parser.add_argument('--timebase-numer', type=int, required=True)
parser.add_argument('--timebase-denom', type=int, required=True)
parser.add_argument('--output')
parser.add_argument('--key-pattern', help='Repeating observed tap roles: letter,space,delete; requires --expected-keys')
parser.add_argument('--key-prefix', help='Optional initial tap roles before the repeating pattern')
parser.add_argument('--expected-keys', type=int)
args = parser.parse_args()
if args.timebase_numer <= 0 or args.timebase_denom <= 0:
    parser.error('Timebase values must be positive')
pattern = args.key_pattern.split(',') if args.key_pattern else []
prefix = args.key_prefix.split(',') if args.key_prefix else []
if prefix and not pattern:
    parser.error('--key-prefix requires --key-pattern')
if pattern and (any(role not in {'letter', 'space', 'delete'} for role in prefix + pattern)
                or not args.expected_keys or args.expected_keys <= 0):
    parser.error('Use only letter,space,delete roles and a positive --expected-keys')
scale = args.timebase_numer / args.timebase_denom / 1_000_000
opener = gzip.open if args.input.endswith('.gz') else open
starts, intervals = {}, []
unmatched_ends = collections.Counter()
with opener(args.input, 'rt') as source:
    for line in source:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get('eventType') != 'signpostEvent':
            continue
        if event.get('subsystem') != 'lk.org.akshara.keyboard' or event.get('category') != 'Performance':
            continue
        key = (event['processID'], event['signpostID'], event['signpostName'])
        if event['signpostType'] == 'begin':
            starts[key] = event
        elif event['signpostType'] == 'end':
            begin = starts.pop(key, None)
            if begin is None:
                unmatched_ends[event['signpostName']] += 1
                continue
            intervals.append(dict(name=begin['signpostName'],
                start=begin['machTimestamp'] * scale,
                end=event['machTimestamp'] * scale,
                ms=(event['machTimestamp'] - begin['machTimestamp']) * scale,
                thread=begin['threadID'], metadata=begin.get('eventMessage', ''),
                process=begin['processID']))

host_names = {'HostReadBefore', 'HostReadAfter', 'HostReadSelection',
              'HostInsert', 'HostDelete', 'HostMoveCaret'}
owned = []
for key in (item for item in intervals if item['name'] == 'KeyHandling'):
    spans = sorted((item['start'], item['end']) for item in intervals
        if item['process'] == key['process'] and item['thread'] == key['thread']
        and item['name'] in host_names and key['start'] <= item['start']
        and item['end'] <= key['end'])
    merged = []
    for start, end in spans:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    owned.append(key['ms'] - sum(end - start for start, end in merged))

keys = sorted((item for item in intervals if item['name'] == 'KeyHandling'), key=lambda item: item['start'])
if pattern:
    # Unnamed background pairs can be malformed in unified-log exports;
    # they do not invalidate a complete paired KeyHandling tap sequence.
    bad_keys = any(key[2] == 'KeyHandling' for key in starts) or unmatched_ends['KeyHandling']
    if len(keys) != args.expected_keys or bad_keys:
        parser.error('Tap roles require exactly the expected number of complete key intervals')
    if len(keys) <= len(prefix) or (len(keys) - len(prefix)) % len(pattern):
        parser.error('Tap roles require complete repetitions after the optional prefix')
    if len({key['process'] for key in keys}) != 1:
        parser.error('Tap-role attribution requires one extension process per input file')
    roles = prefix + pattern * ((len(keys) - len(prefix)) // len(pattern))

def summarize(name, durations):
    ordered = sorted(durations)
    if ordered:
        p95 = ordered[math.ceil(len(ordered) * .95) - 1]
        print(f'| {name} | {len(ordered)} | {statistics.median(ordered):.4f} | {p95:.4f} | {ordered[-1]:.4f} |')

print('| Interval | Samples | Median ms | p95 ms | Max ms |')
print('|---|---:|---:|---:|---:|')
for name in sorted({item['name'] for item in intervals}):
    summarize(name, [item['ms'] for item in intervals if item['name'] == name])
summarize('KeyHandling excluding nested host calls', owned)
if pattern:
    for role in sorted(set(roles)):
        summarize(f'KeyHandling ({role} tap)', [key['ms'] for key, observed_role in zip(keys, roles)
                  if observed_role == role])
if starts or unmatched_ends:
    print('Excluded unmatched starts:', dict(collections.Counter(key[2] for key in starts)))
    print('Excluded unmatched ends:', dict(unmatched_ends))
if args.output:
    with open(args.output, 'w') as target:
        json.dump(intervals, target, indent=2)
        target.write('\n')
