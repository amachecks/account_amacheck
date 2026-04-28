import json
import urllib.request
import urllib.error


def amacheck_request_json(url, api_key, payload=None, method="POST"):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": "Bearer " + api_key,
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
