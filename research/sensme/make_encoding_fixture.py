"""Compact generated formatter oracles for public regression; omit private inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


GENERATED_KINDS = {'generated-encoding', 'boundary-encoding',
                   'empty-encoding', 'generated-encoding-stress'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--oracle', type=Path, action='append', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    features, beats, cases = [], [], []
    feature_indices, beat_indices = {}, {}
    for path in args.oracle:
        for item in json.loads(path.read_text())['cases']:
            if item['kind'] not in GENERATED_KINDS:
                continue
            words = tuple(item['words'])
            if len(words) != 189:
                raise ValueError('Expected 189 feature words')
            if words not in feature_indices:
                feature_indices[words] = len(features)
                features.append(words)
            raw = bytes.fromhex(item['beatsHex'])
            if len(raw) % 168:
                raise ValueError('Partial beat record')
            # Encoding only reads time/bar/beat/class, root and section label.
            packed = b''.join(raw[i:i+16] + raw[i+112:i+116] + raw[i+164:i+168]
                              for i in range(0, len(raw), 168))
            if packed not in beat_indices:
                beat_indices[packed] = len(beats)
                beats.append([struct.unpack_from('<Iiiiii', packed, i)
                              for i in range(0, len(packed), 24)])
            encoded = bytes.fromhex(item['encodedHex'])
            if (len(encoded) != item['encodedBytes'] or
                    hashlib.sha256(encoded).hexdigest() != item['encodedSHA256']):
                raise ValueError('Oracle output digest mismatch')
            cases.append(dict(feature=feature_indices[words], beats=beat_indices[packed],
                              **{key: item[key] for key in
                                 ('processedFrames', 'volumeBits', 'chorusType', 'chorusBeat',
                                  'sampleOffset', 'encodedBytes', 'encodedSHA256')}))
    args.out.write_text(json.dumps(dict(schemaVersion=1,
        source='Original default 1.6.1 formatter on generated inputs only; normalization disabled',
        features=features, beats=beats, cases=cases), separators=(',', ':')) + '\n')
    print(json.dumps(dict(cases=len(cases), featureSets=len(features), beatSets=len(beats))))


if __name__ == '__main__':
    main()
