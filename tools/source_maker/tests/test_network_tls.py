import datetime
import json
import ssl
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from core import BrowserRequired, Fetcher, discover
from network_tls import CertificateTrustError, trust_context


class TLSChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        root = Path(cls.directory.name)
        now = datetime.datetime.now(datetime.timezone.utc)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'SourceMaker Test CA')])
        ca = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=10))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(True,False,False,False,False,True,True,False,False),critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()),critical=False).sign(key,hashes.SHA256()))
        leaf_key = rsa.generate_private_key(public_exponent=65537,key_size=2048)
        leaf = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'localhost')]))
            .issuer_name(subject).public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(days=1)).not_valid_after(now+datetime.timedelta(days=2))
            .add_extension(x509.BasicConstraints(ca=False,path_length=None),critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]),critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(key.public_key()),critical=False).sign(key,hashes.SHA256()))
        cls.ca_path=root/'ca.pem';cls.ca_path.write_bytes(ca.public_bytes(serialization.Encoding.PEM))
        chain=root/'server.pem';chain.write_bytes(leaf.public_bytes(serialization.Encoding.PEM)+ca.public_bytes(serialization.Encoding.PEM))
        private=root/'key.pem';private.write_bytes(leaf_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"ok":true}')
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(str(chain),str(private))
        cls.server.socket=context.wrap_socket(cls.server.socket,server_side=True)
        threading.Thread(target=cls.server.serve_forever,daemon=True).start()
        cls.url=f'https://localhost:{cls.server.server_port}/'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.directory.cleanup()

    def trusted(self):
        return ssl.create_default_context(cafile=str(self.ca_path))

    def test_combined_context_keeps_verification_and_bundled_roots(self):
        context=trust_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode,ssl.CERT_REQUIRED)
        self.assertGreater(context.cert_store_stats()['x509_ca'],100)

    def test_verified_https_page_and_script_request_both_work(self):
        with patch('network_tls.trust_context',return_value=self.trusted()):
            fetcher=Fetcher()
        self.assertTrue(json.loads(fetcher.get(self.url)[1])['ok'])
        self.assertEqual(fetcher.request({'url':self.url})['status'],200)

    def test_untrusted_issuer_is_rejected_for_both_request_paths(self):
        with patch('network_tls.trust_context',return_value=ssl.create_default_context()):
            fetcher=Fetcher()
        with self.assertRaises(CertificateTrustError):fetcher.get(self.url)
        with self.assertRaises(CertificateTrustError):fetcher.request({'url':self.url})

    def test_wrong_hostname_is_rejected_even_with_trusted_issuer(self):
        with patch('network_tls.trust_context',return_value=self.trusted()):
            fetcher=Fetcher()
        wrong=self.url.replace('localhost','127.0.0.1')
        with self.assertRaisesRegex(CertificateTrustError,'网址不匹配'):
            fetcher.get(wrong)

    def test_discovery_gives_browser_route_for_certificate_failure(self):
        with patch('network_tls.trust_context',return_value=ssl.create_default_context()):fetcher=Fetcher()
        with self.assertRaises(BrowserRequired):discover(self.url,'video',fetcher)
