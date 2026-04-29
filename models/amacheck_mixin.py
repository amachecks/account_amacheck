import json
import urllib.request
import urllib.error

_LICENSE_API_URL = "https://www.wattcollc.com/amachecksapi/api_validate_license.php"
_LICENSE_API_KEY = "8f3c91d7a4b2e6c9f8a1d3b7c5e2f4a9d6c3b1e7f9a2c4d6b8e1f3a5c7d9b2"


def amacheck_get_credentials(license_code):
    """Call the AMAChecks license API and return (api_code, checks_left).
    Raises Exception with a user-friendly message on any failure.
    """
    if not license_code:
        raise Exception(
            "AMAChecks License Code is not configured. "
            "Go to Settings > AMACheck to enter your license code."
        )

    payload = json.dumps({"LicenseCode": license_code}).encode("utf-8")
    req = urllib.request.Request(
        _LICENSE_API_URL,
        data=payload,
        headers={
            "X-API-KEY": _LICENSE_API_KEY,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise Exception("AMAChecks license server returned an error: %s" % str(e))
    except Exception as e:
        raise Exception("Could not reach the AMAChecks license server: %s" % str(e))

    if not result.get("success"):
        raise Exception(
            "AMAChecks license validation failed: %s"
            % result.get("error", "Unknown error")
        )

    return result.get("APICode"), result.get("ChecksLeft", 0)


def amacheck_request_json(url, api_code, payload=None, method="POST"):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": "Bearer " + api_code,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method=method,
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            body = response.read().decode("utf-8")
            return json.loads(body) if body else {}

    except urllib.error.HTTPError as e:
        try:
            error_body = e.read().decode("utf-8")
            return json.loads(error_body) if error_body else {
                "success": False,
                "errorMsg": str(e),
            }
        except Exception:
            return {
                "success": False,
                "errorMsg": str(e),
            }
