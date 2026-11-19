# /// script
# requires-python = ">=3.10"
# dependencies = ["fido2==2.2.1", "playwright==1.65.2"]
# ///
"""Exercise the tinyTouch test's relying party with Chrome's virtual authenticator."""

from pathlib import Path
from runpy import run_path

from fido2.webauthn import AuthenticationResponse, RegistrationResponse
from playwright.sync_api import sync_playwright


def main():
    trial = run_path(str(Path(__file__).resolve().parents[1] / "scripts/try-fido2.py"))
    origin = trial["ORIGIN"]
    with sync_playwright() as driver:
        browser = driver.chromium.launch(channel="chrome")
        page = browser.new_page()
        def serve_local_page(route):
            if route.request.url == origin + "/":
                route.fulfill(content_type="text/html", body="<title>FIDO test</title>")
            else:
                route.abort()

        page.route("**/*", serve_local_page)
        page.goto(origin)
        cdp = page.context.new_cdp_session(page)
        cdp.send("WebAuthn.enable")
        key = cdp.send("WebAuthn.addVirtualAuthenticator", {"options": {
            "protocol": "ctap2", "ctap2Version": "ctap2_1", "transport": "usb",
            "hasUserVerification": True, "hasPrf": True, "isUserVerified": True,
            "automaticPresenceSimulation": True,
        }})["authenticatorId"]

        def register(options):
            raw = page.evaluate("""async input => (await navigator.credentials.create({
                publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(input)
            })).toJSON()""", dict(options))
            return RegistrationResponse.from_dict(raw)

        last_request = None

        def authenticate(options):
            nonlocal last_request
            last_request = dict(options)
            raw = page.evaluate("""async input => (await navigator.credentials.get({
                publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(input)
            })).toJSON()""", last_request)
            return AuthenticationResponse.from_dict(raw)

        print("Khóa ảo Chrome, xác minh người dùng mô phỏng.", flush=True)
        trial["try_credential"](register, authenticate)

        saved = None

        def replay(options):
            nonlocal saved
            if saved is None:
                saved = authenticate(options)
            return saved

        try:
            trial["try_credential"](register, replay)
        except ValueError as error:
            if "challenge" not in str(error).lower():
                raise
        else:
            raise AssertionError("An old assertion was accepted for a new challenge")

        cdp.send("WebAuthn.setUserVerified", {"authenticatorId": key, "isUserVerified": False})

        outcome = page.evaluate("""async input => {
            const publicKey = PublicKeyCredential.parseRequestOptionsFromJSON(input);
            publicKey.challenge = crypto.getRandomValues(new Uint8Array(32));
            try {
                await navigator.credentials.get({publicKey, signal: AbortSignal.timeout(3000)});
                return 'accepted';
            } catch (error) { return error.name; }
        }""", last_request)
        if outcome not in ("NotAllowedError", "TimeoutError", "AbortError"):
            raise AssertionError(f"Unexpected assertion result without UV: {outcome}")
        print("Đạt trên khóa ảo. Challenge cũ bị từ chối và thiếu UV không xác thực được.")
        browser.close()


if __name__ == "__main__":
    main()
