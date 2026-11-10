"""NIST ECC and ECDSA compatibility backed by bundled cryptography.

Imports stay lazy, as in lume_rsa, for Spiders that only import ECC.
"""
import sys
import types

# NIST prime-curve subgroup orders (RFC 6979, Appendix A.2.3--A.2.7).
_ORDERS = {
    'secp192r1': int('FFFFFFFFFFFFFFFFFFFFFFFF99DEF836146BC9B1B4D22831', 16),
    'secp224r1': int('FFFFFFFFFFFFFFFFFFFFFFFFFFFF16A2E0B8F03E13DD29455C5C2A3D', 16),
    'secp256r1': int('FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551', 16),
    'secp384r1': int('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973', 16),
    'secp521r1': int('1FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFA51868783BF2F966B7FCC0148F709A5D03BB5C9B8899C47AEBB6FB71E91386409', 16),
}


def _curve(name):
    from cryptography.hazmat.primitives.asymmetric import ec
    aliases = {
        '192': (ec.SECP192R1, ('p192', 'p-192', 'nist p-192', 'secp192r1', 'prime192v1')),
        '224': (ec.SECP224R1, ('p224', 'p-224', 'nist p-224', 'secp224r1')),
        '256': (ec.SECP256R1, ('p256', 'p-256', 'nist p-256', 'secp256r1', 'prime256v1')),
        '384': (ec.SECP384R1, ('p384', 'p-384', 'nist p-384', 'secp384r1')),
        '521': (ec.SECP521R1, ('p521', 'p-521', 'nist p-521', 'secp521r1')),
    }
    for factory, names in aliases.values():
        if str(name).lower() in names:
            return factory()
    raise ValueError('Unsupported ECC curve: ' + str(name))


class _EcdhPoint:
    def __init__(self, public_key):
        self._key = public_key
        numbers = public_key.public_numbers()
        self.x, self.y = numbers.x, numbers.y

    def __mul__(self, scalar):
        from cryptography.hazmat.primitives.asymmetric import ec
        private = ec.derive_private_key(int(scalar), self._key.curve)
        # Spider handshakes consume only the shared X coordinate. Keep this
        # operation in the bundled native backend, as with ordinary ECDH.
        return types.SimpleNamespace(x=int.from_bytes(private.exchange(ec.ECDH(), self._key), 'big'))

    __rmul__ = __mul__


class EccKey:
    def __init__(self, key):
        self._key = key

    def has_private(self):
        from cryptography.hazmat.primitives.asymmetric import ec
        return isinstance(self._key, ec.EllipticCurvePrivateKey)

    def public_key(self):
        return EccKey(self._key.public_key()) if self.has_private() else self

    @property
    def curve(self):
        return 'NIST P-' + str(self._key.curve.key_size)

    @property
    def d(self):
        return self._key.private_numbers().private_value

    @property
    def pointQ(self):
        return _EcdhPoint(self.public_key()._key)

    def export_key(self, *, format='PEM', compress=False, passphrase=None,
                   use_pkcs8=True, **kwargs):
        from cryptography.hazmat.primitives import serialization as s
        if kwargs:
            raise ValueError('Unsupported ECC export options: ' + ', '.join(kwargs))
        if format in ('SEC1', 'raw'):
            if self.has_private():
                raise ValueError('SEC1/raw export requires a public key')
            return self._key.public_bytes(s.Encoding.X962,
                s.PublicFormat.CompressedPoint if compress else s.PublicFormat.UncompressedPoint)
        if format not in ('PEM', 'DER', 'OpenSSH'):
            raise ValueError('Unsupported ECC export format')
        encoding = {'PEM': s.Encoding.PEM, 'DER': s.Encoding.DER,
                    'OpenSSH': s.Encoding.OpenSSH}[format]
        if self.has_private():
            if format == 'OpenSSH':
                raise ValueError('OpenSSH export requires a public key')
            secret = passphrase.encode() if isinstance(passphrase, str) else passphrase
            value = self._key.private_bytes(encoding,
                s.PrivateFormat.PKCS8 if use_pkcs8 else s.PrivateFormat.TraditionalOpenSSL,
                s.BestAvailableEncryption(secret) if secret else s.NoEncryption())
        else:
            value = self._key.public_bytes(encoding,
                s.PublicFormat.OpenSSH if format == 'OpenSSH' else s.PublicFormat.SubjectPublicKeyInfo)
        return value.decode() if format in ('PEM', 'OpenSSH') else value


def construct(*, curve, d=None, point_x=None, point_y=None):
    from cryptography.hazmat.primitives.asymmetric import ec
    backend = _curve(curve)
    if d is not None:
        key = EccKey(ec.derive_private_key(int(d), backend))
        if point_x is not None or point_y is not None:
            if (key.pointQ.x, key.pointQ.y) != (point_x, point_y):
                raise ValueError('ECC public and private components do not match')
        return key
    return EccKey(ec.EllipticCurvePublicNumbers(int(point_x), int(point_y), backend).public_key())


def generate(*, curve, randfunc=None):
    from cryptography.hazmat.primitives.asymmetric import ec
    if randfunc is not None:
        raise ValueError('Custom ECC random functions are unsupported')
    return EccKey(ec.generate_private_key(_curve(curve)))


def import_key(encoded, passphrase=None, curve_name=None):
    from cryptography.hazmat.primitives import serialization as s
    from cryptography.hazmat.primitives.asymmetric import ec
    data = encoded.encode() if isinstance(encoded, str) else bytes(encoded)
    password = passphrase.encode() if isinstance(passphrase, str) else passphrase
    if curve_name is not None and data and data[0] in (2, 3, 4):
        return EccKey(ec.EllipticCurvePublicKey.from_encoded_point(_curve(curve_name), data))
    for loader in (s.load_pem_private_key, s.load_der_private_key):
        try:
            key = loader(data, password=password)
            if isinstance(key, ec.EllipticCurvePrivateKey):
                return EccKey(key)
        except (TypeError, ValueError):
            pass
    for loader in (s.load_pem_public_key, s.load_der_public_key, s.load_ssh_public_key):
        try:
            key = loader(data)
            if isinstance(key, ec.EllipticCurvePublicKey):
                return EccKey(key)
        except (TypeError, ValueError):
            pass
    raise ValueError('Invalid ECC key or passphrase')


class _Dss:
    def __init__(self, key, mode, encoding='binary', randfunc=None):
        if mode not in ('fips-186-3', 'deterministic-rfc6979') or encoding not in ('binary', 'der'):
            raise ValueError('Unsupported DSS mode or encoding')
        if randfunc is not None:
            raise ValueError('Custom DSS random functions are unsupported')
        self.key, self.mode, self.encoding = key, mode, encoding

    def _algorithm(self, digest, deterministic=False):
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from lume_rsa import _hash
        return ec.ECDSA(utils.Prehashed(_hash(digest)),
                        deterministic_signing=deterministic)

    def _deterministic_signature(self, digest):
        """RFC 6979 for bundled OpenSSL versions lacking native deterministic ECDSA.

        Curve multiplication still uses cryptography/OpenSSL. Never substitute
        a random signature when a Spider explicitly requests deterministic mode.
        """
        import hashlib
        import hmac
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from lume_rsa import _hash
        order = _ORDERS[self.key._key.curve.name]
        bits, size = order.bit_length(), (order.bit_length() + 7) // 8
        name = _hash(digest).name
        length = hashlib.new(name).digest_size

        def integer(data):
            return int.from_bytes(data, 'big') >> max(0, len(data) * 8 - bits)

        def mac(key, data):
            return hmac.new(key, data, name).digest()

        hashed = digest.digest()
        secret = self.key.d
        seed = secret.to_bytes(size, 'big') + (integer(hashed) % order).to_bytes(size, 'big')
        value, key = b'\x01' * length, b'\x00' * length
        key = mac(key, value + b'\x00' + seed)
        value = mac(key, value)
        key = mac(key, value + b'\x01' + seed)
        value = mac(key, value)
        while True:
            candidate = b''
            while len(candidate) < size:
                value = mac(key, value)
                candidate += value
            nonce = integer(candidate)
            if 1 <= nonce < order:
                point = ec.derive_private_key(nonce, self.key._key.curve).public_key().public_numbers()
                r = point.x % order
                s = (pow(nonce, -1, order) * (integer(hashed) + r * secret)) % order
                if r and s:
                    return utils.encode_dss_signature(r, s)
            key = mac(key, value + b'\x00')
            value = mac(key, value)

    def sign(self, digest):
        from cryptography.exceptions import UnsupportedAlgorithm
        from cryptography.hazmat.primitives.asymmetric import utils
        try:
            value = self.key._key.sign(digest.digest(), self._algorithm(digest,
                deterministic=self.mode == 'deterministic-rfc6979'))
        except UnsupportedAlgorithm:
            if self.mode != 'deterministic-rfc6979':
                raise
            value = self._deterministic_signature(digest)
        if self.encoding == 'der':
            return value
        r, s = utils.decode_dss_signature(value)
        size = (self.key._key.curve.key_size + 7) // 8
        return r.to_bytes(size, 'big') + s.to_bytes(size, 'big')

    def verify(self, digest, signature):
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives.asymmetric import utils
        value = bytes(signature)
        if self.encoding == 'binary':
            size = (self.key._key.curve.key_size + 7) // 8
            if len(value) != size * 2:
                raise ValueError('Invalid ECDSA signature length')
            value = utils.encode_dss_signature(int.from_bytes(value[:size], 'big'),
                                               int.from_bytes(value[size:], 'big'))
        try:
            self.key.public_key()._key.verify(value, digest.digest(), self._algorithm(digest))
        except InvalidSignature as error:
            raise ValueError('Invalid ECDSA signature') from error


def install(crypto):
    ecc = types.ModuleType('Crypto.PublicKey.ECC')
    ecc.EccKey, ecc.construct, ecc.generate, ecc.import_key = EccKey, construct, generate, import_key
    dss = types.ModuleType('Crypto.Signature.DSS')
    dss.new = _Dss
    crypto.PublicKey.ECC, crypto.Signature.DSS = ecc, dss
    sys.modules[ecc.__name__], sys.modules[dss.__name__] = ecc, dss
