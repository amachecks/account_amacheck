from odoo import models, fields


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
        default="sandbox",
    )
