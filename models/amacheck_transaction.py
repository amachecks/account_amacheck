import base64
import csv
import io
import json
import logging

from odoo import api, fields, models
from odoo.exceptions import UserError

from .amacheck_mixin import AMACheckError, amacheck_get_check_status, amacheck_get_transactions

_logger = logging.getLogger(__name__)

_STATUS_LABELS = {
    "processing":  "Processing",
    "ready":       "Ready",
    "printed":     "Printed",
    "mailed":      "Mailed",
    "pre_transit": "Pre-Transit",
    "transit":     "In Transit",
    "delivery":    "Out for Delivery",
    "delivered":   "Delivered",
    "pdf":         "PDF Returned",
}

_SEND_STATES = [
    ("sent",        "Sent"),
    ("failed",      "Failed"),
    ("unconfirmed", "Unconfirmed"),
    ("pending",     "Pending"),
]


def _license_code(env):
    return env["ir.config_parameter"].sudo().get_param("account_amacheck.license_code")


class AMACheckTransactionLine(models.TransientModel):
    _name = "amacheck.transaction.line"
    _description = "AMACheck Transaction Log Line"

    wizard_id     = fields.Many2one("amacheck.transaction.wizard", ondelete="cascade")
    trans_date    = fields.Datetime(string="Transaction Date", readonly=True)
    check_no      = fields.Char(string="Check Number", readonly=True)
    payee         = fields.Char(string="Payee", readonly=True)
    bank          = fields.Char(string="Bank", readonly=True)
    bank_account  = fields.Char(string="Account", readonly=True)
    amount        = fields.Float(string="Amount", digits=(16, 2), readonly=True)
    send_state    = fields.Selection(_SEND_STATES, string="Result", readonly=True)
    result        = fields.Text(string="Details", readonly=True)
    checkeeper_id = fields.Char(string="Check ID", readonly=True)

    # Fetched live from AMAChecks only when a line is opened
    check_status = fields.Char(string="Mail Status", compute="_compute_check_status", store=False)

    def _compute_check_status(self):
        license_code = _license_code(self.env)
        for line in self:
            if line.send_state != "sent" or not line.checkeeper_id:
                line.check_status = ""
                continue
            try:
                raw = amacheck_get_check_status(license_code, line.checkeeper_id)
                line.check_status = _STATUS_LABELS.get(raw, raw.replace("_", " ").title())
            except AMACheckError as e:
                _logger.warning("AMACheck status fetch failed for %s: %s", line.checkeeper_id, e)
                line.check_status = "Unavailable"


class AMACheckTransactionWizard(models.TransientModel):
    _name = "amacheck.transaction.wizard"
    _description = "AMACheck Transaction Log"

    line_ids     = fields.One2many("amacheck.transaction.line", "wizard_id", string="Transactions", readonly=True)
    csv_file     = fields.Binary(string="CSV File", readonly=True, attachment=False)
    csv_filename = fields.Char(string="CSV Filename", readonly=True)

    @api.model
    def action_open(self):
        try:
            transactions = amacheck_get_transactions(_license_code(self.env))
        except AMACheckError as e:
            raise UserError(str(e))

        states = {key for key, _label in _SEND_STATES}
        lines = []
        for t in transactions:
            state = t.get("Status") or ("sent" if t.get("CheckNo") else "failed")
            result = t.get("Result") or ""
            # Older rows stored the whole provider response; show it readably.
            try:
                result = json.dumps(json.loads(result), indent=2)
            except (ValueError, TypeError):
                pass
            lines.append((0, 0, {
                "trans_date":    t.get("TransDate") or False,
                "check_no":      str(t.get("CheckNo") or ""),
                "payee":         t.get("Payee") or "",
                "bank":          t.get("Bank") or "",
                "bank_account":  t.get("BankAccount") or "",
                "amount":        float(t.get("Amount") or 0),
                "send_state":    state if state in states else False,
                "result":        result,
                "checkeeper_id": t.get("CheckeeperID") or "",
            }))

        wizard = self.create({"line_ids": lines})
        return {
            "type":      "ir.actions.act_window",
            "name":      "Transaction Log",
            "res_model": "amacheck.transaction.wizard",
            "res_id":    wizard.id,
            "view_mode": "form",
            "target":    "current",
        }

    def action_export_csv(self):
        self.ensure_one()
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(["Transaction Date", "Check Number", "Payee", "Bank", "Account", "Amount", "Result"])
        labels = dict(_SEND_STATES)
        for line in self.line_ids:
            writer.writerow([
                fields.Datetime.to_string(line.trans_date) if line.trans_date else "",
                line.check_no or "",
                line.payee or "",
                line.bank or "",
                line.bank_account or "",
                "%.2f" % line.amount,
                labels.get(line.send_state, ""),
            ])

        self.write({
            "csv_file":     base64.b64encode(output.getvalue().encode("utf-8-sig")),
            "csv_filename": "amacheck_transactions.csv",
        })
        return {
            "type":   "ir.actions.act_url",
            "url":    "/web/content?model=amacheck.transaction.wizard&id=%d&field=csv_file&filename=%s&download=true"
                      % (self.id, self.csv_filename),
            "target": "new",
        }
