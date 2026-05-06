import json
import urllib.request
import urllib.error

_BASE_URL = "https://api.amachecks.com/private"

_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "AMAChecks-Odoo/1.0",
}


class AMACheckLicenseInactiveError(Exception):
    pass


def _post(endpoint, payload, api_key=None):
    if api_key:
        payload["APIKey"] = api_key
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
    """Validate license and return the full API result dict.
    Raises AMACheckLicenseInactiveError if inactive, Exception for other failures.
    No API key required — the license code is the authentication for this endpoint.
    """
    if not license_code:
        raise Exception(
            "AMAChecks License Code is not configured. "
            "Go to Settings > AMACheck to enter your license code."
        )

    result = _post("api_validate_license.php", {
        "LicenseCode": license_code,
    })

    if not result.get("success"):
        error = result.get("error", "Unknown error")
        error_lower = (error or "").lower()
        if "inactive" in error_lower:
            raise AMACheckLicenseInactiveError()
        raise Exception(
            "Invalid AMAChecks license code. "
            "Please check the License Code in Settings > AMACheck."
        )

    return result


def amacheck_sync_bank_account(license_code, bank_payload, api_key):
    """Sync a bank account with the check provider. Returns bankAccountId."""
    payload = {"LicenseCode": license_code}
    payload.update(bank_payload)
    result = _post("api_sync_bank_account.php", payload, api_key=api_key)
    if not result.get("success"):
        raise Exception(result.get("error", "Bank account sync failed"))
    return result["bankAccountId"]


def amacheck_send_check(license_code, bank_account_id, payee_id, amount, memo, vendor, api_key):
    """Send a check via OCW. Returns the full result dict with checkId, checkNumber, payeeId, checksLeft."""
    result = _post("api_send_check.php", {
        "LicenseCode":   license_code,
        "bankAccountId": bank_account_id,
        "payeeId":       payee_id or None,
        "amount":        amount,
        "memo":          memo,
        "vendor":        vendor,
    }, api_key=api_key)
    if not result.get("success"):
        raise Exception(result.get("error", "Check send failed"))
    return result


def amacheck_log_transaction(license_code, check_no, payee, bank, bank_account, amount, result, api_key):
    """Log a check transaction to TransactionLog via the PHP endpoint."""
    masked = ("****" + str(bank_account)[-4:]) if bank_account else ""
    try:
        _post("api_log_transaction.php", {
            "LicenseCode": license_code,
            "checkNo":     check_no or "",
            "payee":       payee or "",
            "bank":        bank or "",
            "bankAccount": masked,
            "amount":      amount,
            "result":      result if isinstance(result, str) else json.dumps(result),
        }, api_key=api_key)
    except Exception as e:
        # Never let logging failure interrupt the payment flow
        import logging
        logging.getLogger(__name__).warning("AMAChecks TransactionLog failed: %s", str(e))


def checkeeper_post(url, api_key, payload):
    """POST to the Checkeeper API with Bearer auth.
    Returns (http_status_code, result_dict).
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            status = response.getcode()
            return status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        status = e.code
        try:
            raw = e.read().decode("utf-8")
        except Exception:
            raw = ""
        try:
            return status, json.loads(raw)
        except Exception:
            return status, {"error": "%s — %s" % (str(e), raw) if raw else str(e)}
    except Exception as e:
        raise Exception("Could not reach AMAChecks API: %s" % str(e))
