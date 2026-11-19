#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["fido2==2.2.1"]
# ///
"""Try a disposable WebAuthn credential on a connected tinyTouch. Run with uv."""

import re
import sys
from secrets import token_bytes

from fido2.client import ClientError, DefaultClientDataCollector, Fido2Client
from fido2.ctap import CtapError
from fido2.ctap2 import Ctap2
from fido2.hid import CtapHidDevice, list_descriptors, open_connection
from fido2.server import Fido2Server
from fido2.utils import websafe_decode, websafe_encode
from fido2.webauthn import PublicKeyCredentialRpEntity, PublicKeyCredentialUserEntity


RP_ID = "tinytouch.test"
ORIGIN = "https://tinytouch.test"


def try_credential(register, authenticate):
    server = Fido2Server(
        PublicKeyCredentialRpEntity(id=RP_ID, name="tinyTouch local test"),
        verify_origin=lambda origin: origin == ORIGIN,
    )
    server.timeout = 30_000
    user = PublicKeyCredentialUserEntity(id=token_bytes(32), name="local-test", display_name="tinyTouch test")
    options, state = server.register_begin(
        user,
        authenticator_attachment="cross-platform",
        resident_key_requirement="discouraged",
        user_verification="required",
        extensions={"prf": {}},
    )
    print("Đăng ký credential thử.", flush=True)
    response = register(options.public_key)
    credential = server.register_complete(state, response).credential_data
    if credential is None or not response.client_extension_results.get("prf", {}).get("enabled"):
        raise ValueError("Thiết bị chưa tạo được credential có PRF.")

    salt = websafe_encode(token_bytes(32))
    other_salt = websafe_encode(token_bytes(32))
    previous = None
    for attempt in (1, 2):
        options, state = server.authenticate_begin(
            [credential], user_verification="required",
            extensions={"prf": {"eval": {"first": salt, "second": other_salt}}},
        )
        print(f"Xác thực thử lần {attempt}/2.", flush=True)
        response = authenticate(options.public_key)
        server.authenticate_complete(state, [credential], response)
        outputs = response.client_extension_results.get("prf", {}).get("results", {})
        first = websafe_decode(outputs.get("first", ""))
        second = websafe_decode(outputs.get("second", ""))
        if len(first) != 32 or len(second) != 32 or first == second:
            raise ValueError("Hai đầu vào PRF phải trả về hai kết quả 32 byte khác nhau.")
        if previous is not None and (first, second) != previous:
            raise ValueError("Kết quả PRF đã thay đổi với cùng credential và đầu vào.")
        previous = first, second
    print("Đạt. Đã kiểm tra hai chữ ký, cờ UP/UV và kết quả PRF.")


def main():
    matches = [
        item for item in list_descriptors()
        if (item.vid, item.pid) == (0x303A, 0x4001)
        and (
            item.product_name == "tinyTouch"
            or re.fullmatch(r"TT-[0-9a-fA-F]{12}", item.serial_number or "")
        )
    ]
    if not matches:
        raise ValueError("Không tìm thấy giao diện FIDO USB của tinyTouch (303a:4001).")
    if len(matches) > 1:
        raise ValueError("Tìm thấy nhiều giao diện FIDO của tinyTouch. Chỉ kết nối một thiết bị để thử.")

    descriptor = matches[0]
    with CtapHidDevice(descriptor, open_connection(descriptor)) as device:
        info = Ctap2(device).info
        built_in_uv = info.options.get("uv") is True
        hmac_secret = "hmac-secret" in info.extensions
        print(f"CTAP {', '.join(info.versions)}, uv={built_in_uv}, hmac-secret={hmac_secret}")
        if not built_in_uv or not hmac_secret:
            raise ValueError("Phép thử cần xác minh người dùng trên thiết bị (uv=true) và hmac-secret.")
        # The default interaction declines a PIN request, keeping the trial on built-in UV.
        client = Fido2Client(device, DefaultClientDataCollector(ORIGIN))
        print("Chạm ngón tay đã đăng ký mỗi khi tinyTouch yêu cầu.", flush=True)
        try_credential(client.make_credential, lambda options: client.get_assertion(options).get_response(0))


if __name__ == "__main__":
    try:
        main()
    except (ClientError, CtapError, OSError, ValueError) as error:
        sys.exit(str(error))
