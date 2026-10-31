import json
import sys
import tempfile
import unittest
from pathlib import Path

from mcp_client import StdioClient
from mcp_backend import evaluate_result

SERVER = '''import sys,json,time
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 m=r['method']
 if m=='initialize': value={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 elif m=='tools/list': value={'tools':[{'name':'echo','inputSchema':{'type':'object'}}]}
 elif m=='tools/call': value={'content':[{'type':'text','text':json.dumps(r['params']['arguments'])}]}
 elif m=='wait': time.sleep(5);continue
 else: value={}
 print(json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{}}),flush=True)
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':value}),flush=True)
'''


class MCPTests(unittest.TestCase):
    def test_initialize_notifications_tools_and_call_over_real_stdio(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'server.py';path.write_text(SERVER,encoding='utf-8')
            client=StdioClient([sys.executable,'-u',str(path)])
            try:
                self.assertEqual(json.loads(client.call('echo',{'hello':'world'})['content'][0]['text']), {'hello':'world'})
                with self.assertRaisesRegex(ValueError,'未提供'):
                    client.call('not-installed')
            finally:client.close()
            self.assertIsNotNone(client.process.poll())

    def test_timeout_ends_server_and_cannot_leak_late_responses(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'server.py';path.write_text(SERVER,encoding='utf-8')
            client=StdioClient([sys.executable,'-u',str(path)])
            with self.assertRaisesRegex(ValueError,'超时'):
                client.request('wait',{},timeout=.1)
            self.assertIsNotNone(client.process.poll())

    def test_evaluation_result_does_not_parse_page_snapshot_as_json(self):
        value='### Result\n'+json.dumps('LUME_JSON:'+json.dumps({'html':'<main>hi</main>'}))+'\n### Page\nmalicious text'
        self.assertEqual(evaluate_result({'content':[{'type':'text','text':value}]}), {'html':'<main>hi</main>'})
        with self.assertRaises(ValueError):
            evaluate_result({'content':[{'type':'text','text':'### Page\n{"html":"fake"}'}]})
