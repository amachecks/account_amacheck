from odoo import fields, models
from odoo.exceptions import UserError

from .amacheck_mixin import AMACheckError, amacheck_get_credentials

# System parameters written by versions before 1.2 (shared keys, OCW settings).
# They are no longer used and are removed on upgrade and on Refresh Balance.
LEGACY_PARAMS = (
    "account_amacheck.license_api_key",
    "account_amacheck.checkeeper_api_key",
    "account_amacheck.active_provider",
    "account_amacheck.assign_check_no",
    "account_amacheck.provider_name",
    "account_amacheck.is_ocw",
)


def remove_legacy_params(env):
    env["ir.config_parameter"].sudo().search([("key", "in", LEGACY_PARAMS)]).unlink()


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
    account_amacheck_customer_name = fields.Char(
        string="Licensed To",
        config_parameter="account_amacheck.customer_name",
        readonly=True,
    )

    def set_values(self):
        params = self.env["ir.config_parameter"].sudo()
        old_code = (params.get_param("account_amacheck.license_code") or "").strip()
        super().set_values()
        new_code = (params.get_param("account_amacheck.license_code") or "").strip()
        if new_code != old_code:
            # Balance and name belong to the old license until refreshed.
            params.set_param("account_amacheck.checks_left", "0")
            params.set_param("account_amacheck.customer_name", "")

    def action_amacheck_refresh_status(self):
        """Save the license code shown on screen, then load its balance."""
        self.ensure_one()
        params = self.env["ir.config_parameter"].sudo()
        license_code = (self.account_amacheck_license_code or "").strip()
        params.set_param("account_amacheck.license_code", license_code)
        remove_legacy_params(self.env)

        try:
            result = amacheck_get_credentials(license_code)
        except AMACheckError as e:
            params.set_param("account_amacheck.checks_left", "0")
            params.set_param("account_amacheck.customer_name", "")
            raise UserError(str(e))

        params.set_param("account_amacheck.checks_left", str(int(result.get("ChecksLeft") or 0)))
        params.set_param("account_amacheck.customer_name", result.get("CustomerName") or "")
        return {"type": "ir.actions.client", "tag": "reload"}

    def action_view_transactions(self):
        self.ensure_one()
        license_code = (self.account_amacheck_license_code or "").strip()
        saved = (self.env["ir.config_parameter"].sudo().get_param("account_amacheck.license_code") or "").strip()
        if license_code != saved:
            raise UserError("Click Refresh Balance (or Save) to use the new license code first.")
        return self.env["amacheck.transaction.wizard"].action_open()
