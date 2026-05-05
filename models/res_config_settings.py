from odoo import models, fields
from odoo.exceptions import UserError
import urllib.request
import json

_LICENSE_API_URL = "http://www.wattcollc.com/amachecksapi/private/api_validate_license.php"
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

    account_amacheck_active_provider = fields.Integer(
        string="Active Provider ID",
        config_parameter="account_amacheck.active_provider",
        readonly=True,
    )

    account_amacheck_allow_sandbox = fields.Boolean(
        string="Allow Sandbox Mode",
        config_parameter="account_amacheck.allow_sandbox",
        readonly=True,
    )

    account_amacheck_is_ocw = fields.Boolean(
        string="Is Online Check Writer",
        compute="_compute_account_amacheck_is_ocw",
    )

    def _compute_account_amacheck_is_ocw(self):
        is_ocw = bool(self.env["ir.config_parameter"].sudo().get_param("account_amacheck.is_ocw"))
        for record in self:
            record.account_amacheck_is_ocw = is_ocw

    def action_amacheck_refresh_status(self):
        license_code = self.account_amacheck_license_code
        if not license_code:
            raise UserError("Please enter your AMACheck License Code before refreshing.")

        environment = self.env["ir.config_parameter"].sudo().get_param(
            "account_amacheck.environment", "production"
        )
        payload = json.dumps({"LicenseCode": license_code, "Environment": environment}).encode("utf-8")
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

        params = self.env["ir.config_parameter"].sudo()
        params.set_param("account_amacheck.checks_left", str(result.get("ChecksLeft", 0)))

        if "ProviderID" in result:
            params.set_param("account_amacheck.active_provider", str(result["ProviderID"]))

        if "ProviderAPIKey" in result:
            params.set_param("account_amacheck.checkeeper_api_key", result["ProviderAPIKey"])

        allow_sandbox = result.get("AllowSandbox", True)
        params.set_param("account_amacheck.allow_sandbox", "1" if allow_sandbox else "")
        if not allow_sandbox:
            params.set_param("account_amacheck.environment", "production")

        assign_check_no = result.get("AssignCheckNo", False)
        params.set_param("account_amacheck.assign_check_no", "1" if assign_check_no else "")

        provider_name = result.get("ProviderName", "")
        params.set_param("account_amacheck.provider_name", provider_name)
        params.set_param("account_amacheck.is_ocw", "1" if provider_name == "OnlineCheckWriter" else "")

        return {"type": "ir.actions.client", "tag": "reload"}
