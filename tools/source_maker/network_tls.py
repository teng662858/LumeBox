"""Verified HTTPS using both platform trust and the shipped Mozilla root bundle."""
import ssl
from functools import lru_cache
from pathlib import Path

import certifi


@lru_cache(maxsize=1)
def trust_context():
    # Keep corporate/platform roots, and add Mozilla roots which may not have
    # reached Windows' automatic root update on a particular PC.
    context = ssl.create_default_context()
    bundle = Path(certifi.where())
    if not bundle.is_file():
        raise ValueError('工具的根证书文件缺失，请重新下载完整版本')
    context.load_verify_locations(cafile=str(bundle))
    return context


def certificate_error(error):
    reason = getattr(error, 'reason', error)
    return isinstance(reason, ssl.SSLCertVerificationError)


class CertificateTrustError(ValueError):
    def __init__(self, error):
        reason = getattr(error, 'reason', error)
        code = getattr(reason, 'verify_code', None)
        detail = {10:'站点证书已过期', 9:'站点证书尚未生效',
                  18:'站点使用未受信任的自签名证书', 19:'证书链包含未受信任证书',
                  20:'证书链或根证书不完整', 21:'无法验证完整证书链',
                  62:'证书主机名与网址不匹配', 64:'证书地址与网址不匹配'}.get(code, '无法验证站点身份')
        super().__init__('HTTPS 证书校验未通过：' + detail + '。已使用系统和内置根证书，请用浏览器检查或联系站点修复证书。')
