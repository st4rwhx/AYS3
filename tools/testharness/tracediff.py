#!/usr/bin/env python3
"""Differential trace comparator for AYS3. See TESTING.md for the trace format.

Compares a reference trace (known-correct, e.g. RPCS3 desktop) against a
candidate trace (our fork) and reports the first point of divergence, with
surrounding context, instead of requiring a manual line-by-line log diff.

Zero third-party dependencies: stdlib only, so it runs in CI without a
package install step.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from typing import Any, TextIO


REQUIRED_FIELDS_BY_KIND = {
    "ppu_block": {"seq", "kind", "pc", "regs_hash", "instr_count"},
    "spu_block": {"seq", "kind", "spu_id", "pc", "regs_hash", "instr_count"},
    "frame": {"seq", "kind", "frame_index", "frame_hash"},
}


class TraceFormatError(ValueError):
    pass


@dataclass
class Divergence:
    index: int
    kind: str  # "missing_reference" | "missing_candidate" | "seq_mismatch" | "content_mismatch"
    reference: dict[str, Any] | None
    candidate: dict[str, Any] | None
    mismatched_field: str | None = None
    context: list[tuple[dict[str, Any] | None, dict[str, Any] | None]] = field(default_factory=list)

    def format(self) -> str:
        lines = [f"first divergence at index {self.index} ({self.kind})"]
        if self.mismatched_field:
            lines.append(f"  field: {self.mismatched_field}")
        lines.append(f"  reference: {self.reference}")
        lines.append(f"  candidate: {self.candidate}")
        if self.context:
            lines.append("  context (ref | candidate):")
            for ref_rec, cand_rec in self.context:
                lines.append(f"    {ref_rec} | {cand_rec}")
        return "\n".join(lines)


def parse_trace(handle: TextIO, source_name: str = "<trace>") -> list[dict[str, Any]]:
    records = []
    for lineno, raw_line in enumerate(handle, start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise TraceFormatError(f"{source_name}:{lineno}: invalid JSON: {exc}") from exc
        if "kind" not in record:
            raise TraceFormatError(f"{source_name}:{lineno}: missing 'kind' field")
        kind = record["kind"]
        required = REQUIRED_FIELDS_BY_KIND.get(kind)
        if required is None:
            raise TraceFormatError(f"{source_name}:{lineno}: unknown kind '{kind}'")
        missing = required - record.keys()
        if missing:
            raise TraceFormatError(f"{source_name}:{lineno}: kind '{kind}' missing fields {sorted(missing)}")
        records.append(record)
    return records


def diff_traces(reference: list[dict[str, Any]], candidate: list[dict[str, Any]], context: int = 3) -> Divergence | None:
    length = max(len(reference), len(candidate))
    for i in range(length):
        ref_rec = reference[i] if i < len(reference) else None
        cand_rec = candidate[i] if i < len(candidate) else None

        if ref_rec is None:
            return _with_context(Divergence(i, "missing_reference", ref_rec, cand_rec), reference, candidate, i, context)
        if cand_rec is None:
            return _with_context(Divergence(i, "missing_candidate", ref_rec, cand_rec), reference, candidate, i, context)
        if ref_rec.get("seq") != cand_rec.get("seq"):
            return _with_context(Divergence(i, "seq_mismatch", ref_rec, cand_rec), reference, candidate, i, context)

        mismatched_field = _first_content_mismatch(ref_rec, cand_rec)
        if mismatched_field is not None:
            return _with_context(
                Divergence(i, "content_mismatch", ref_rec, cand_rec, mismatched_field=mismatched_field),
                reference,
                candidate,
                i,
                context,
            )
    return None


def _first_content_mismatch(ref_rec: dict[str, Any], cand_rec: dict[str, Any]) -> str | None:
    compare_fields = {"kind", "pc", "spu_id", "regs_hash", "frame_index", "frame_hash"}
    for key in compare_fields:
        if key in ref_rec or key in cand_rec:
            if ref_rec.get(key) != cand_rec.get(key):
                return key
    return None


def _with_context(
    divergence: Divergence,
    reference: list[dict[str, Any]],
    candidate: list[dict[str, Any]],
    index: int,
    context: int,
) -> Divergence:
    start = max(0, index - context)
    end = index + 1
    ctx = []
    for i in range(start, end):
        ref_rec = reference[i] if i < len(reference) else None
        cand_rec = candidate[i] if i < len(candidate) else None
        ctx.append((ref_rec, cand_rec))
    divergence.context = ctx
    return divergence


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", help="path to the reference trace.jsonl (known-correct)")
    parser.add_argument("candidate", help="path to the candidate trace.jsonl (our fork)")
    parser.add_argument("--context", type=int, default=3, help="records of context to print around a divergence")
    args = parser.parse_args(argv)

    try:
        with open(args.reference, encoding="utf-8") as ref_file:
            reference = parse_trace(ref_file, args.reference)
        with open(args.candidate, encoding="utf-8") as cand_file:
            candidate = parse_trace(cand_file, args.candidate)
    except (OSError, TraceFormatError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    divergence = diff_traces(reference, candidate, context=args.context)
    if divergence is None:
        print(f"MATCH: {len(reference)} records, no divergence")
        return 0

    print(divergence.format())
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
