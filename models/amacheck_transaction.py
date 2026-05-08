import base64
import csv
import io

from odoo import models, fields, api
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_transactions, amacheck_get_check_status

# Human-readable labels for Checkeeper status values
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

    def action_check_status(self):
        self.ensure_one()

        if not self.checkeeper_id:
            raise UserError(
                "No provider check ID found for check #%s. "
                "Status is only available for checks sent via the online check service."
                % (self.check_no or "(unknown)")
            )

        params          = self.env["ir.config_parameter"].sudo()
        license_code    = params.get_param("account_amacheck.license_code")
        license_api_key = params.get_param("account_amacheck.license_api_key") or ""

        try:
            result = amacheck_get_check_status(self.checkeeper_id, license_code, license_api_key)
        except Exception as e:
            raise UserError("Could not retrieve check status: %s" % str(e))

        raw_status  = result.get("status", "unknown")
        label       = _STATUS_LABELS.get(raw_status, raw_status.replace("_", " ").title())
        data        = result.get("data") or {}

        # Build detail lines from available data
        details = []
        if data.get("tracking_number"):
            details.append("Tracking: %s" % data["tracking_number"])
        if data.get("carrier"):
            details.append("Carrier: %s" % data["carrier"])
        if data.get("estimated_delivery"):
            details.append("Estimated Delivery: %s" % data["estimated_delivery"])
        if data.get("updated_at"):
            details.append("Last Updated: %s" % data["updated_at"])

        popup = self.env["amacheck.status.popup"].create({
            "check_no":     self.check_no or "",
            "checkeeper_id": self.checkeeper_id,
            "status":       label,
            "raw_status":   raw_status,
            "tracking_no":  data.get("tracking_number") or "",
            "carrier":      data.get("carrier") or "",
            "est_delivery": data.get("estimated_delivery") or "",
            "updated_at":   data.get("updated_at") or "",
        })

        return {
            "type":      "ir.actions.act_window",
            "name":      "Check Status",
            "res_model": "amacheck.status.popup",
            "res_id":    popup.id,
            "view_mode": "form",
            "target":    "new",
        }


class AMACheckStatusPopup(models.TransientModel):
    _name = "amacheck.status.popup"
    _description = "AMACheck Check Status"

    check_no       = fields.Char(string="Check Number", readonly=True)
    checkeeper_id  = fields.Char(string="Check ID", readonly=True)
    status         = fields.Char(string="Status", readonly=True)
    raw_status     = fields.Char(string="Raw Status", readonly=True)
    tracking_no    = fields.Char(string="Tracking Number", readonly=True)
    carrier        = fields.Char(string="Carrier", readonly=True)
    est_delivery   = fields.Char(string="Estimated Delivery", readonly=True)
    updated_at     = fields.Char(string="Last Updated", readonly=True)


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
            check_no = t.get("CheckNo") or ""
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
            "target":    "new",
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
