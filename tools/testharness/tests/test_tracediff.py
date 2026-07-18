import io
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import tracediff  # noqa: E402


def records_to_jsonl(records):
    import json

    return "\n".join(json.dumps(r) for r in records) + "\n"


PPU_OK = {"seq": 1, "kind": "ppu_block", "pc": "0x1000", "regs_hash": "sha256:aaa", "instr_count": 10}
SPU_OK = {"seq": 2, "kind": "spu_block", "spu_id": 0, "pc": "0x20", "regs_hash": "sha256:bbb", "instr_count": 5}
FRAME_OK = {"seq": 3, "kind": "frame", "frame_index": 0, "frame_hash": "sha256:ccc"}


class TestParseTrace(unittest.TestCase):
    def test_parses_valid_records(self):
        text = records_to_jsonl([PPU_OK, SPU_OK, FRAME_OK])
        records = tracediff.parse_trace(io.StringIO(text))
        self.assertEqual(len(records), 3)

    def test_skips_blank_lines(self):
        text = records_to_jsonl([PPU_OK]) + "\n\n"
        records = tracediff.parse_trace(io.StringIO(text))
        self.assertEqual(len(records), 1)

    def test_rejects_invalid_json(self):
        with self.assertRaises(tracediff.TraceFormatError):
            tracediff.parse_trace(io.StringIO("{not json\n"))

    def test_rejects_unknown_kind(self):
        bad = {**PPU_OK, "kind": "mystery"}
        with self.assertRaises(tracediff.TraceFormatError):
            tracediff.parse_trace(io.StringIO(records_to_jsonl([bad])))

    def test_rejects_missing_fields(self):
        bad = {"seq": 1, "kind": "ppu_block"}
        with self.assertRaises(tracediff.TraceFormatError):
            tracediff.parse_trace(io.StringIO(records_to_jsonl([bad])))


class TestDiffTraces(unittest.TestCase):
    def test_identical_traces_match(self):
        trace = [PPU_OK, SPU_OK, FRAME_OK]
        result = tracediff.diff_traces(trace, list(trace))
        self.assertIsNone(result)

    def test_content_mismatch_detected(self):
        candidate = [PPU_OK, {**SPU_OK, "regs_hash": "sha256:DIFFERENT"}, FRAME_OK]
        result = tracediff.diff_traces([PPU_OK, SPU_OK, FRAME_OK], candidate)
        self.assertIsNotNone(result)
        self.assertEqual(result.kind, "content_mismatch")
        self.assertEqual(result.index, 1)
        self.assertEqual(result.mismatched_field, "regs_hash")

    def test_frame_hash_mismatch_detected(self):
        candidate = [PPU_OK, SPU_OK, {**FRAME_OK, "frame_hash": "sha256:DIFFERENT"}]
        result = tracediff.diff_traces([PPU_OK, SPU_OK, FRAME_OK], candidate)
        self.assertEqual(result.kind, "content_mismatch")
        self.assertEqual(result.mismatched_field, "frame_hash")

    def test_missing_candidate_record_detected(self):
        result = tracediff.diff_traces([PPU_OK, SPU_OK], [PPU_OK])
        self.assertEqual(result.kind, "missing_candidate")
        self.assertEqual(result.index, 1)

    def test_missing_reference_record_detected(self):
        result = tracediff.diff_traces([PPU_OK], [PPU_OK, SPU_OK])
        self.assertEqual(result.kind, "missing_reference")
        self.assertEqual(result.index, 1)

    def test_seq_mismatch_detected(self):
        candidate = [PPU_OK, {**SPU_OK, "seq": 999}]
        result = tracediff.diff_traces([PPU_OK, SPU_OK], candidate)
        self.assertEqual(result.kind, "seq_mismatch")
        self.assertEqual(result.index, 1)

    def test_divergence_includes_context(self):
        trace = [PPU_OK, SPU_OK, FRAME_OK]
        bad_frame = {**FRAME_OK, "frame_hash": "sha256:DIFFERENT"}
        result = tracediff.diff_traces(trace, [PPU_OK, SPU_OK, bad_frame], context=1)
        self.assertEqual(len(result.context), 2)


class TestMainCLI(unittest.TestCase):
    def test_main_returns_zero_on_match(self, tmp_path=None):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            ref_path = pathlib.Path(tmp) / "ref.jsonl"
            cand_path = pathlib.Path(tmp) / "cand.jsonl"
            ref_path.write_text(records_to_jsonl([PPU_OK, SPU_OK]))
            cand_path.write_text(records_to_jsonl([PPU_OK, SPU_OK]))
            rc = tracediff.main([str(ref_path), str(cand_path)])
            self.assertEqual(rc, 0)

    def test_main_returns_one_on_divergence(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            ref_path = pathlib.Path(tmp) / "ref.jsonl"
            cand_path = pathlib.Path(tmp) / "cand.jsonl"
            ref_path.write_text(records_to_jsonl([PPU_OK]))
            cand_path.write_text(records_to_jsonl([{**PPU_OK, "regs_hash": "sha256:DIFFERENT"}]))
            rc = tracediff.main([str(ref_path), str(cand_path)])
            self.assertEqual(rc, 1)

    def test_main_returns_two_on_missing_file(self):
        rc = tracediff.main(["/nonexistent/ref.jsonl", "/nonexistent/cand.jsonl"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
