from odoo import models, fields
from odoo.exceptions import UserError
import urllib.request
import json

_LICENSE_API_URL = "https://api.amachecks.com/private/api_validate_license.php"
_LICENSE_API_KEY = "8f3c91d7a4b2e6c9f8a1d3b7c5e2f4a9d6c3b1e7f9a2c4d6b8e1f3a5c7d9b2"


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    account_amacheck_api_key = fields.Char(
        string="AMACheck API Key",
        config_parameter="account_amacheck.api_key"
    )

    account_amacheck_environment = fields.Selection(
        selection=[("sandbox", "Sandbox"), ("production", "Production")],
        string="AMACheck Environment",
        config_parameter="account_amacheck.environment",
        default="production",
    )

    account_amacheck_license_code = fields.Char(
        string="License Code",
        config_parameter="account_amacheck.license_code",
    )

    account_amacheck_checks_left = fields.Integer(
        string="eChecks Available",
        config_parameter="account_amacheck.checks_left",
        readonly=True,
    )

    def action_amacheck_refresh_status(self):
        license_code = self.account_amacheck_license_code
        if not license_code:
            raise UserError("Please enter your AMACheck License Code before refreshing.")

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
        except Exception as e:
            raise UserError("Could not reach the AMACheck license server: %s" % str(e))

        if not result.get("success"):
            raise UserError(
                "AMACheck license validation failed: %s"
                % result.get("error", "Unknown error")
            )

        checks_left = result.get("ChecksLeft", 0)
        self.env["ir.config_parameter"].sudo().set_param(
            "account_amacheck.checks_left", str(checks_left)
        )

        return {"type": "ir.actions.client", "tag": "reload"}
