"""Offline regression checks for sources/video/咕噜咕噜.py."""
import importlib.util
import json
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "sources/video/咕噜咕噜.py"
SPEC = importlib.util.spec_from_file_location("gulu_source", SOURCE)
gulu = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gulu)


class FakeProtocol:
    session_id = "session"
    players = {"line": {"name": "测试线路", "parser_ids": [7]}}
    parsers = {7: {"server": True}}
    last_detail_error = ""

    def __init__(self):
        self.calls = []

    def boot(self):
        raise AssertionError("metadata/categories must not boot the network")

    def search(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return {"videos": [], "pagecount": 1, "limit": 21, "total": 0}

    def detail(self, _):
        return {
            "id": "1", "name": "测试剧", "pic": "", "year": "", "area": "",
            "remarks": "", "content": "", "sources": [{
                "name": "测试线路", "parser_id": 7, "episodes": [{
                    "id": "part@one#two$three", "name": "第1集", "index": 1,
                }],
            }],
        }

    def play(self, parser_id, play_id):
        self.calls.append((parser_id, play_id))
        return "https://picovr.com/path/video.m3u8"


class GuluSourceTests(unittest.TestCase):
    def spider(self):
        source = gulu.Spider()
        source.protocol = FakeProtocol()
        return source

    def test_categories_are_immediate_and_do_not_make_network_calls(self):
        source = self.spider()
        result = source.homeContent(filter=True)
        self.assertEqual(len(result["class"]), 6)
        self.assertEqual(result["list"], [])
        self.assertEqual(source.protocol.calls, [])

    def test_episode_token_preserves_delimiters_and_headers_use_resolved_host(self):
        source = self.spider()
        detail = source.detailContent("1")["list"][0]
        token = detail["vod_play_url"].split("$", 1)[1]
        self.assertNotIn("@", token)
        played = source.playerContent("", token)
        self.assertEqual(played["url"], "https://picovr.com/path/video.m3u8")
        self.assertNotIn("Referer", json.loads(played["header"]))
        self.assertEqual(source.protocol.calls[-1], (7, "part@one#two$three"))

    def test_empty_playback_response_is_a_clear_failure(self):
        source = self.spider()
        detail = source.detailContent("1")["list"][0]
        token = detail["vod_play_url"].split("$", 1)[1]
        source.protocol.play = lambda *_: ""
        with self.assertRaisesRegex(RuntimeError, "切换线路"):
            source.playerContent("", token)


if __name__ == "__main__":
    unittest.main(verbosity=2)
