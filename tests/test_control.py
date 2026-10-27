import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import control  # noqa: E402


class ControlContractTests(unittest.TestCase):
    def test_topology_has_unique_nodes_and_links(self):
        data = control.topology()["topology"]
        node_ids = {node["id"] for node in data["nodes"]}
        self.assertEqual(len(node_ids), len(data["nodes"]))
        self.assertEqual(len({link["id"] for link in data["links"]}), len(data["links"]))
        for link in data["links"]:
            self.assertGreaterEqual(len(link["endpoints"]), 2)
            for endpoint in link["endpoints"]:
                self.assertIn(endpoint["node"], node_ids)

    def test_dynamic_operations_are_not_claimed(self):
        caps = control.topology()["topology"]["capabilities"]
        self.assertTrue(caps["read_topology"])
        self.assertTrue(caps["read_status"])
        self.assertFalse(caps["create_node"])
        self.assertFalse(caps["delete_node"])
        self.assertFalse(caps["change_links"])

    def test_status_contains_each_known_node(self):
        original = control.node_status
        try:
            control.node_status = lambda node: {"id": node["id"], "state": "stopped"}
            data = control.status()
        finally:
            control.node_status = original
        self.assertEqual(data["state"], "stopped")
        self.assertEqual(len(data["nodes"]), len(control.NODES))


if __name__ == "__main__":
    unittest.main()
