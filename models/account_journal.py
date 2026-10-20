from odoo import fields, models


class AccountJournal(models.Model):
    _inherit = "account.journal"

    amacheck_signer = fields.Char(
        string="Signer", copy=False,
        help="Name printed as the signature on checks sent from this journal.",
    )
    amacheck_next_check_no = fields.Integer(
        string="Next Check Number", default=10000, copy=False,
        help="Number printed on the next check sent from this journal. "
             "Increases by one after each check is sent.",
    )
