"""Validate a compiled OCR component without loading GPU drivers."""
import argparse
from pathlib import Path
from build_ocr_acceleration import verify

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--platform')
    parser.add_argument('--arch')
    args = parser.parse_args()
    verify(args.directory, args.platform, args.arch)
    print('Pinned OCR GPU component verified:', args.directory)
