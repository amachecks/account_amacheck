"""Client for the AMAChecks API (api.amachecks.com/private).

The customer's Odoo talks only to AMAChecks, authenticated by its license
code. AMAChecks sends the check to Checkeeper on its own servers, so no
provider key or shared API key is ever stored in this database.
"""
import json
import logging
import urllib.error
import urllib.request

_logger = logging.getLogger(__name__)

_BASE_URL = "https://api.amachecks.com/private"

_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "AMAChecks-Odoo/1.2",
}


class AMACheckError(Exception):
    """An error reported by the AMAChecks API. `code` is machine-readable."""

    def __init__(self, message, code="error", data=None):
        super().__init__(message)
        self.code = code
        self.data = data or {}


class AMACheckLicenseInactiveError(AMACheckError):
    def __init__(self, message="Your AMAChecks license is inactive.", code="inactive", data=None):
        super().__init__(message, code, data)


def _post(endpoint, payload, api_key=None, timeout=20):
    """POST JSON to an AMAChecks endpoint and return the decoded response.

    Returns the response dict for both success and API-level failures
    ({"success": false, ...}), so callers can read `code` and `checksLeft`.
    Raises AMACheckError only when AMAChecks can't be reached or doesn't
    answer with JSON.

    `api_key` is only for AMA Systems' own admin calls (crediting eChecks
    from the store); customer calls never send one.
    """
    payload = dict(payload)
    if api_key:
        payload["APIKey"] = api_key
    req = urllib.request.Request(
        _BASE_URL + "/" + endpoint.lstrip("/"),
        data=json.dumps(payload).encode("utf-8"),
        headers=_HEADERS,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = None
        if isinstance(body, dict):
            body.setdefault("success", False)
            body.setdefault("error", "HTTP %s" % e.code)
            return body
        raise AMACheckError("AMAChecks API error (HTTP %s)" % e.code, "server_error")
    except Exception as e:  # timeout, DNS, TLS, connection refused...
        raise AMACheckError("Could not reach AMAChecks: %s" % e, "unreachable")

    try:
        body = json.loads(raw)
    except ValueError:
        body = None
    if not isinstance(body, dict):
        raise AMACheckError("AMAChecks returned an unreadable response", "server_error")
    return body


def _raise_for_failure(result, default):
    if result.get("success"):
        return result
    code = result.get("code") or "error"
    message = result.get("error") or default
    if code == "inactive":
        raise AMACheckLicenseInactiveError(message, code, result)
    raise AMACheckError(message, code, result)


def _require_license(license_code):
    if not (license_code or "").strip():
        raise AMACheckError(
            "AMAChecks License Code is not configured. "
            "Go to Settings > AMACheck, enter your license code and click Refresh Balance.",
            "license_required",
        )
    return license_code.strip()


def amacheck_get_credentials(license_code):
    """Validate a license. Returns {CustomerName, ChecksLeft, Sandbox, ...}.
    Raises AMACheckLicenseInactiveError if inactive, AMACheckError otherwise."""
    license_code = _require_license(license_code)
    result = _post("api_validate_license.php", {"LicenseCode": license_code})
    return _raise_for_failure(result, "Invalid AMAChecks license code.")


def amacheck_send_check(license_code, client_ref, check):
    """Ask AMAChecks to mail one check. Returns the response dict:
      success → {checkId, checkNumber, checksLeft, sandbox}
      failure → {code, error, checksLeft}
    Raises AMACheckError if AMAChecks couldn't be reached at all."""
    license_code = _require_license(license_code)
    # AMAChecks waits up to 45s for Checkeeper; give it room.
    return _post(
        "api_send_check.php",
        {"LicenseCode": license_code, "ClientRef": client_ref, "Check": check},
        timeout=75,
    )


def amacheck_get_transactions(license_code):
    """This license's check history (newest first)."""
    license_code = _require_license(license_code)
    result = _post("api_get_transactions.php", {"LicenseCode": license_code})
    return _raise_for_failure(result, "Failed to fetch transactions").get("transactions", [])


def amacheck_get_check_status(license_code, check_id):
    """Live mail status of one of this license's checks, e.g. 'mailed'."""
    license_code = _require_license(license_code)
    result = _post("api_get_check_status.php", {"LicenseCode": license_code, "CheckID": check_id})
    return _raise_for_failure(result, "Failed to fetch check status").get("status", "unknown")
