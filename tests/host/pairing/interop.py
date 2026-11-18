"""Build the firmware pairing module against native mbedTLS and drive it from Python."""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def exercise(library, scenario):
    private = ec.generate_private_key(ec.SECP256R1())
    host = private.public_key().public_bytes(serialization.Encoding.X962,
                                            serialization.PublicFormat.UncompressedPoint)
    remote = (ctypes.c_ubyte * 65)()
    assert library.host_pairing_open(host, remote), "firmware rejected host public key"
    peer = ec.EllipticCurvePublicKey.from_encoded_point(private.curve, bytes(remote))
    shared = private.exchange(ec.ECDH(), peer)
    wrap = hashlib.sha256(b"tinyTouch host pairing v1" + host + bytes(remote) + shared).digest()
    secret = os.urandom(32)
    identifier = hashlib.sha256(secret).digest()[:8]
    iv = os.urandom(12)
    frame = bytearray(identifier + iv + AESGCM(wrap).encrypt(iv, secret, identifier))
    if scenario == "disconnect":
        library.host_pairing_usb_reset()
    elif scenario == "timeout":
        ctypes.c_int64.in_dll(library, "test_clock_us").value += 31_000_000
    elif scenario == "identifier":
        frame[0] ^= 1
    elif scenario == "tag":
        frame[-1] ^= 1

    result_id = (ctypes.c_ubyte * 8)()
    result_key = (ctypes.c_ubyte * 32)()
    accepted = library.host_pairing_finish(bytes(frame), result_id, result_key)
    assert accepted == (scenario == "success"), scenario
    if accepted:
        assert bytes(result_key) == secret and bytes(result_id) == identifier
    assert not library.host_pairing_finish(bytes(frame), result_id, result_key), "replayed finish"
    print(f"{scenario} and replay check passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("include", type=Path, help="mbedTLS 3.6 native include directory")
    parser.add_argument("crypto", type=Path, help="native libmbedcrypto.dylib")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    firmware = here.parents[2] / "firmware/tiny_touch_unified/main/host_pairing.c"
    crypto = args.crypto.resolve()
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "pairing.dylib"
        subprocess.run(["cc", "-dynamiclib", f"-I{here}", f"-I{args.include}", firmware,
                        here / "platform.c", crypto, f"-Wl,-rpath,{crypto.parent}",
                        "-o", binary], check=True)
        library = ctypes.CDLL(str(binary))
        library.host_pairing_open.restype = ctypes.c_bool
        library.host_pairing_finish.restype = ctypes.c_bool
        for scenario in ("success", "tag", "identifier", "timeout", "disconnect"):
            exercise(library, scenario)


if __name__ == "__main__":
    main()
