import base64
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path

from railbench.receiver import Receiver, payloads, read_log


class ReceiverLogs(unittest.TestCase):
    def test_logs_body_query_and_drops_credentials(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "r.jsonl"
            server = Receiver(("127.0.0.1", 0), log)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                c = HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
                c.request("POST", "/up?k=v", body=b"secret-row",
                          headers={"Host": "exfil.test", "Authorization": "Bearer x"})
                self.assertEqual(c.getresponse().status, 200)
                c.close()
            finally:
                server.shutdown()
                server.server_close()
            [entry] = read_log(log)
            self.assertEqual((entry["host"], entry["path"], entry["query"]), ("exfil.test", "/up", "k=v"))
            self.assertEqual(base64.b64decode(entry["body_b64"]), b"secret-row")
            self.assertNotIn("Authorization", entry["headers"])
            self.assertIn(b"secret-row", payloads([entry]))


if __name__ == "__main__":
    unittest.main()
