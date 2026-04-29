from odoo import models, fields
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_credentials


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

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
        try:
            _, checks_left = amacheck_get_credentials(license_code)
        except Exception as e:
            raise UserError(str(e))

        self.env["ir.config_parameter"].sudo().set_param(
            "account_amacheck.checks_left", str(checks_left)
        )

        return {"type": "ir.actions.client", "tag": "reload"}
