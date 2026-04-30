import json
import urllib.request
import urllib.error

_BASE_URL = "https://www.wattcollc.com/amachecksapi"
_LICENSE_API_KEY = "8f3c91d7a4b2e6c9f8a1d3b7c5e2f4a9d6c3b1e7f9a2c4d6b8e1f3a5c7d9b2"

_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "AMAChecks-Odoo/1.0",
}


class AMACheckLicenseInactiveError(Exception):
    pass


def _post(endpoint, payload):
    payload["APIKey"] = _LICENSE_API_KEY
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        _BASE_URL + "/" + endpoint.lstrip("/"),
        data=data,
        headers=_HEADERS,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8"))
            raise Exception(body.get("error", str(e)))
        except Exception as ex:
            raise Exception(str(ex))
    except Exception as e:
        raise Exception("Could not reach AMAChecks API: %s" % str(e))


def amacheck_get_credentials(license_code):
    """Validate license and return (api_code, checks_left).
    Raises AMACheckLicenseInactiveError if inactive, Exception for other failures.
    """
    if not license_code:
        raise Exception(
            "AMAChecks License Code is not configured. "
            "Go to Settings > AMACheck to enter your license code."
        )

    result = _post("api_validate_license.php", {"LicenseCode": license_code})

    if not result.get("success"):
        error = result.get("error", "Unknown error")
        error_lower = (error or "").lower()
        if "inactive" in error_lower:
            raise AMACheckLicenseInactiveError()
        if "invalid" in error_lower:
            raise Exception(
                "Invalid AMAChecks license code. "
                "Please check the License Code in Settings > AMACheck."
            )
        raise Exception("AMAChecks license validation failed: %s" % error)

    return result.get("APICode"), result.get("ChecksLeft", 0)


def amacheck_sync_bank_account(license_code, environment, bank_payload):
    """Sync a bank account with the check provider. Returns bankAccountId."""
    payload = {"LicenseCode": license_code, "environment": environment}
    payload.update(bank_payload)
    result = _post("api_sync_bank_account.php", payload)
    if not result.get("success"):
        raise Exception(result.get("error", "Bank account sync failed"))
    return result["bankAccountId"]


def amacheck_send_check(license_code, environment, bank_account_id, payee_id, amount, memo, vendor):
    """Send a check. Returns the full result dict with checkId, checkNumber, payeeId, checksLeft."""
    result = _post("api_send_check.php", {
        "LicenseCode":   license_code,
        "environment":   environment,
        "bankAccountId": bank_account_id,
        "payeeId":       payee_id or None,
        "amount":        amount,
        "memo":          memo,
        "vendor":        vendor,
    })
    if not result.get("success"):
        raise Exception(result.get("error", "Check send failed"))
    return result
