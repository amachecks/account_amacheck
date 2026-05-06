from odoo import models, fields
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_credentials


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

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

    account_amacheck_is_ocw = fields.Boolean(
        string="Is Online Check Writer",
        compute="_compute_account_amacheck_is_ocw",
    )

    def _compute_account_amacheck_is_ocw(self):
        is_ocw = bool(self.env["ir.config_parameter"].sudo().get_param("account_amacheck.is_ocw"))
        for record in self:
            record.account_amacheck_is_ocw = is_ocw

    def action_amacheck_refresh_status(self):
        params = self.env["ir.config_parameter"].sudo()
        license_code = self.account_amacheck_license_code

        try:
            result = amacheck_get_credentials(license_code)
        except Exception as e:
            raise UserError(str(e))

        params.set_param("account_amacheck.checks_left", str(result.get("ChecksLeft", 0)))

        if "ProviderID" in result:
            params.set_param("account_amacheck.active_provider", str(result["ProviderID"]))

        if "ProviderAPIKey" in result:
            params.set_param("account_amacheck.checkeeper_api_key", result["ProviderAPIKey"])

        if "LicenseAPIKey" in result:
            params.set_param("account_amacheck.license_api_key", result["LicenseAPIKey"])

        assign_check_no = result.get("AssignCheckNo", False)
        params.set_param("account_amacheck.assign_check_no", "1" if assign_check_no else "")

        provider_name = result.get("ProviderName", "")
        params.set_param("account_amacheck.provider_name", provider_name)
        params.set_param("account_amacheck.is_ocw", "1" if provider_name == "OnlineCheckWriter" else "")

        return {"type": "ir.actions.client", "tag": "reload"}
