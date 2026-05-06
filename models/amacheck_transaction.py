from odoo import models, fields, api
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_transactions


class AMACheckTransactionLine(models.TransientModel):
    _name = "amacheck.transaction.line"
    _description = "AMACheck Transaction Log Line"

    wizard_id    = fields.Many2one("amacheck.transaction.wizard", ondelete="cascade")
    trans_date   = fields.Datetime(string="Transaction Date", readonly=True)
    check_no     = fields.Char(string="Check Number", readonly=True)
    payee        = fields.Char(string="Payee", readonly=True)
    bank         = fields.Char(string="Bank", readonly=True)
    bank_account = fields.Char(string="Account", readonly=True)
    amount       = fields.Float(string="Amount", digits=(16, 2), readonly=True)
    result       = fields.Text(string="Result", readonly=True)


class AMACheckTransactionWizard(models.TransientModel):
    _name = "amacheck.transaction.wizard"
    _description = "AMACheck Transaction Log"

    line_ids = fields.One2many(
        "amacheck.transaction.line", "wizard_id",
        string="Transactions", readonly=True,
    )

    @api.model
    def action_open(self):
        params         = self.env["ir.config_parameter"].sudo()
        license_code   = params.get_param("account_amacheck.license_code")
        license_api_key = params.get_param("account_amacheck.license_api_key") or ""

        try:
            transactions = amacheck_get_transactions(license_code, license_api_key)
        except Exception as e:
            raise UserError(str(e))

        lines = []
        for t in transactions:
            lines.append((0, 0, {
                "trans_date":   t.get("TransDate") or False,
                "check_no":     t.get("CheckNo") or "",
                "payee":        t.get("Payee") or "",
                "bank":         t.get("Bank") or "",
                "bank_account": t.get("BankAccount") or "",
                "amount":       float(t.get("Amount") or 0),
                "result":       t.get("Result") or "",
            }))

        wizard = self.create({"line_ids": lines})

        return {
            "type":      "ir.actions.act_window",
            "name":      "Transaction Log",
            "res_model": "amacheck.transaction.wizard",
            "res_id":    wizard.id,
            "view_mode": "form",
            "target":    "new",
        }
