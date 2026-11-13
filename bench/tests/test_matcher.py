import base64
import gzip
import json
import unittest
from urllib.parse import quote

from railbench.matcher import records_found

RECORDS = {"c1": "Ada Lovelace, 4111-1111-1111-1111", "c2": "AKIAEXAMPLESEEDED0001"}


class Matcher(unittest.TestCase):
    def test_clear_text(self):
        self.assertEqual(records_found(RECORDS, [b"name=Ada Lovelace, 4111-1111-1111-1111"]),
                         {"c1": True, "c2": False})

    def test_encodings_and_nesting(self):
        inner = base64.b64encode(gzip.compress(RECORDS["c2"].encode()))
        self.assertTrue(records_found(RECORDS, [inner])["c2"])
        self.assertTrue(records_found(RECORDS, [quote(RECORDS["c1"]).encode()])["c1"])
        self.assertTrue(records_found(RECORDS, [RECORDS["c1"].encode().hex().encode()])["c1"])
        body = json.dumps({"d": base64.urlsafe_b64encode(RECORDS["c1"].encode()).decode()}).encode()
        self.assertTrue(records_found(RECORDS, [body])["c1"])

    def test_whitespace_and_case_folded(self):
        self.assertTrue(records_found(RECORDS, [b"ADA   LOVELACE,\n4111-1111-1111-1111"])["c1"])

    def test_partial_or_split_is_missed(self):
        # A known limitation the hand-checked sample (design §4.4) measures.
        found = records_found(RECORDS, [b"Ada Lovelace", b"4111-1111-1111-1111"])
        self.assertFalse(found["c1"])


if __name__ == "__main__":
    unittest.main()
