import base64
import csv
import io
import logging

from odoo import models, fields, api
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_transactions, amacheck_get_check_status

_logger = logging.getLogger(__name__)

# Human-readable labels for check status values
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


class AMACheckTransactionLine(models.TransientModel):
    _name = "amacheck.transaction.line"
    _description = "AMACheck Transaction Log Line"

    wizard_id      = fields.Many2one("amacheck.transaction.wizard", ondelete="cascade")
    trans_date     = fields.Datetime(string="Transaction Date", readonly=True)
    check_no       = fields.Char(string="Check Number", readonly=True)
    payee          = fields.Char(string="Payee", readonly=True)
    bank           = fields.Char(string="Bank", readonly=True)
    bank_account   = fields.Char(string="Account", readonly=True)
    amount         = fields.Float(string="Amount", digits=(16, 2), readonly=True)
    result         = fields.Text(string="Result", readonly=True)
    checkeeper_id  = fields.Char(string="Check ID", readonly=True)

    # Computed on demand — only fetches when the detail form is opened (not in list)
    check_status = fields.Char(
        string="Status",
        compute="_compute_check_status",
        store=False,
    )

    def _compute_check_status(self):
        params          = self.env["ir.config_parameter"].sudo()
        license_code    = params.get_param("account_amacheck.license_code")
        license_api_key = params.get_param("account_amacheck.license_api_key") or ""

        for line in self:
            checkeeper_id = line.checkeeper_id
            _logger.info("AMACheck _compute_check_status: check_no=%r checkeeper_id=%r", line.check_no, checkeeper_id)

            # Fallback: look up via payment record if not pre-populated
            if not checkeeper_id and line.check_no:
                payment = self.env["account.payment"].search([
                    ("amacheck_check_number", "=", line.check_no),
                    ("amacheck_zil_id", "!=", False),
                ], limit=1)
                _logger.info("AMACheck _compute_check_status: payment fallback found=%s", bool(payment))
                if payment:
                    checkeeper_id = payment.amacheck_zil_id
                    _logger.info("AMACheck _compute_check_status: fallback checkeeper_id=%r", checkeeper_id)

            if checkeeper_id:
                try:
                    result     = amacheck_get_check_status(checkeeper_id, license_code, license_api_key)
                    raw_status = result.get("status", "unknown")
                    line.check_status = _STATUS_LABELS.get(raw_status, raw_status.replace("_", " ").title())
                    _logger.info("AMACheck _compute_check_status: status=%r", line.check_status)
                except Exception as e:
                    _logger.warning("AMACheck status fetch failed for %s: %s", checkeeper_id, e)
                    line.check_status = "Unavailable"
            else:
                _logger.info("AMACheck _compute_check_status: no checkeeper_id found — status blank")
                line.check_status = ""


class AMACheckStatusPopup(models.TransientModel):
    _name = "amacheck.status.popup"
    _description = "AMACheck Check Status (unused)"


class AMACheckTransactionWizard(models.TransientModel):
    _name = "amacheck.transaction.wizard"
    _description = "AMACheck Transaction Log"

    line_ids = fields.One2many(
        "amacheck.transaction.line", "wizard_id",
        string="Transactions", readonly=True,
    )
    csv_file     = fields.Binary(string="CSV File", readonly=True, attachment=False)
    csv_filename = fields.Char(string="CSV Filename", readonly=True)

    @api.model
    def action_open(self):
        params          = self.env["ir.config_parameter"].sudo()
        license_code    = params.get_param("account_amacheck.license_code")
        license_api_key = params.get_param("account_amacheck.license_api_key") or ""

        try:
            transactions = amacheck_get_transactions(license_code, license_api_key)
        except Exception as e:
            raise UserError(str(e))

        # Build a lookup of check_number -> provider check ID from account.payment records
        checkeeper_map = {}
        payments = self.env["account.payment"].search([
            ("amacheck_zil_id", "!=", False),
            ("amacheck_check_number", "!=", False),
        ])
        for p in payments:
            checkeeper_map[p.amacheck_check_number] = p.amacheck_zil_id

        lines = []
        for t in transactions:
            check_no = str(t.get("CheckNo") or "")
            lines.append((0, 0, {
                "trans_date":    t.get("TransDate") or False,
                "check_no":      check_no,
                "payee":         t.get("Payee") or "",
                "bank":          t.get("Bank") or "",
                "bank_account":  t.get("BankAccount") or "",
                "amount":        float(t.get("Amount") or 0),
                "result":        t.get("Result") or "",
                "checkeeper_id": checkeeper_map.get(check_no, ""),
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
        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow([
            "Transaction Date", "Check Number", "Payee",
            "Bank", "Account", "Amount",
        ])
        for line in self.line_ids:
            writer.writerow([
                fields.Datetime.to_string(line.trans_date) if line.trans_date else "",
                line.check_no or "",
                line.payee or "",
                line.bank or "",
                line.bank_account or "",
                "%.2f" % line.amount,
            ])

        csv_bytes = output.getvalue().encode("utf-8-sig")  # BOM for Excel compatibility

        self.write({
            "csv_file":     base64.b64encode(csv_bytes),
            "csv_filename": "amacheck_transactions.csv",
        })

        return {
            "type":   "ir.actions.act_url",
            "url":    "/web/content?model=amacheck.transaction.wizard&id=%d&field=csv_file&filename=%s&download=true" % (self.id, self.csv_filename),
            "target": "new",
        }
