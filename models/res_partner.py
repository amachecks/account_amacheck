from odoo import models, fields


class ResPartner(models.Model):
    _inherit = "res.partner"

    x_amacheck_payee_id = fields.Char(string="AMACheck Payee ID", copy=False)
