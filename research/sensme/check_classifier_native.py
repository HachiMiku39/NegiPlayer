"""Compare standalone native classifier scores with an audited oracle."""
import argparse
import ctypes as C
import json
from collections import Counter
from pathlib import Path


class Features(C.Structure):
    _fields_ = [('words', C.c_uint32 * 189)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--oracle', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    oracle = json.loads(args.oracle.read_text())
    if oracle['selectors'] != list(range(25, 75)):
        raise ValueError('Expected all 50 classifier selectors')
    library = C.CDLL(str(args.library.resolve()))
    run = library.negi_sensme_classification_score
    run.argtypes = [C.POINTER(Features), C.c_uint, C.POINTER(C.c_int32)]
    run.restype = C.c_int
    mismatches = []
    counts = Counter()
    total = 0
    for index, case in enumerate(oracle['cases']):
        if len(case['words']) != 189 or len(case['outputWords']) != 50:
            raise ValueError('Incomplete prepared features or expected scores')
        features = Features((C.c_uint32 * 189)(*case['words']))
        before = bytes(features)
        for selector, expected in zip(oracle['selectors'], case['outputWords']):
            output = C.c_int32(0x5a5a5a5a)
            status = run(C.byref(features), selector, C.byref(output))
            actual = output.value & 0xffffffff
            total += 1
            if status != 1 or actual != expected:
                counts[selector] += 1
                mismatches.append(dict(case=index, selector=selector, status=status,
                                       expected=expected, actual=actual))
        if bytes(features) != before:
            raise RuntimeError('Native classifier changed caller input')
    result = dict(cases=len(oracle['cases']), scores=total,
                  mismatches=len(mismatches), mismatchesBySelector=dict(counts),
                  firstMismatches=mismatches[:100], exact=not mismatches)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return 0 if result['exact'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
