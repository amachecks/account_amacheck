from odoo import models, fields


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    account_amacheck_api_key = fields.Char(
        string="AMACheck API Key",
        config_parameter="account_amacheck.api_key"
    )

    account_amacheck_base_url = fields.Char(
        string="AMACheck Base URL",
        config_parameter="account_amacheck.base_url",
        default="https://test.onlinecheckwriter.com/api/v3"
    )
