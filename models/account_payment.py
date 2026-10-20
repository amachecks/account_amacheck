import logging

from odoo import fields, models
from odoo.exceptions import UserError

from .amacheck_mixin import AMACheckError, amacheck_send_check

_logger = logging.getLogger(__name__)


class AccountPayment(models.Model):
    _inherit = "account.payment"

    amacheck_state = fields.Selection([
        ("ready",       "Ready"),
        ("sent",        "Sent"),
        ("unconfirmed", "Unconfirmed"),
        ("failed",      "Failed"),
    ], string="AMACheck Status", copy=False)

    # Checkeeper check id (field name kept from earlier versions to preserve data)
    amacheck_zil_id       = fields.Char(string="Check ID", copy=False)
    amacheck_check_number = fields.Char(string="Check Number", copy=False)
    amacheck_sent_at      = fields.Datetime(string="Sent On", copy=False)
    amacheck_error        = fields.Text(string="Errors", copy=False)
    amacheck_inactive     = fields.Boolean(string="License Inactive", default=False, copy=False)

    # ------------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------------

    def _amacheck_check_partner_address(self, partner, label):
        missing = []
        if not partner.name:
            missing.append("Name")
        if not partner.street:
            missing.append("Street Address")
        if not partner.city:
            missing.append("City")
        if not partner.state_id:
            missing.append("State")
        if not partner.zip:
            missing.append("ZIP")
        if not partner.country_id:
            missing.append("Country")
        if missing:
            raise UserError(
                "%s '%s' is missing required fields for AMACheck: %s"
                % (label, partner.name or "(no name)", ", ".join(missing))
            )

    def _amacheck_get_bank_journal(self):
        self.ensure_one()
        journal = self.journal_id
        if not journal or journal.type != "bank":
            raise UserError(
                "Payment '%s' must use a Bank journal to send via AMACheck. "
                "Change the journal on this payment to a bank account journal."
                % (self.name or self.id)
            )

        bank_account = journal.bank_account_id
        if not bank_account:
            raise UserError(
                "Journal '%s' does not have a Bank Account. Go to Accounting > "
                "Configuration > Journals > %s and set one." % (journal.name, journal.name)
            )
        if not bank_account.acc_number:
            raise UserError(
                "The bank account on journal '%s' has no account number." % journal.name
            )
        bank = bank_account.bank_id
        if not bank:
            raise UserError(
                "The bank account on journal '%s' has no Bank set. Open the bank account "
                "and choose the bank (it holds the routing number)." % journal.name
            )
        if not bank.bic:
            raise UserError(
                "Bank '%s' has no routing number. Go to Accounting > Configuration > Banks "
                "and enter the 9-digit routing number as the Bank Identifier Code."
                % (bank.name or "(no name)")
            )
        if not (journal.amacheck_signer or "").strip():
            raise UserError(
                "Signer is not set on journal '%s'. Go to Accounting > Configuration > "
                "Journals > %s > AMACheck Settings." % (journal.name, journal.name)
            )
        return journal

    # ------------------------------------------------------------------
    # Payload
    # ------------------------------------------------------------------

    @staticmethod
    def _amacheck_state_code(partner):
        return partner.state_id.code or partner.state_id.name or ""

    def _amacheck_address_lines(self, partner):
        """Name / street / [street2] / City, ST ZIP — as printed on the check."""
        csz = ", ".join(filter(None, [partner.city, self._amacheck_state_code(partner)]))
        if partner.zip:
            csz = (csz + " " + partner.zip).strip()
        return [line for line in (partner.name, partner.street, partner.street2, csz) if line]

    def _amacheck_address(self, partner, with_company=False):
        address = {
            "name":    partner.name or "",
            "line1":   partner.street or "",
            "line2":   partner.street2 or "",
            "city":    partner.city or "",
            "state":   self._amacheck_state_code(partner),
            "zip":     partner.zip or "",
            "country": partner.country_id.code or "US",
        }
        if with_company:
            address["company"] = (
                partner.commercial_company_name or partner.parent_id.name or partner.name or ""
            )
        return address

    def _amacheck_check_payload(self, journal):
        self.ensure_one()
        vendor       = self.partner_id
        company      = self.company_id.partner_id
        bank_account = journal.bank_account_id
        return {
            "number":       journal.amacheck_next_check_no,
            "date":         fields.Date.context_today(self).strftime("%Y-%m-%d"),
            "amount_cents": int(round(self.amount * 100)),
            "memo":         (self.memo or "")[:120],
            "signer":       journal.amacheck_signer.strip(),
            "bank": {
                "name":    bank_account.bank_id.name or "",
                "routing": bank_account.bank_id.bic or "",
                "account": bank_account.acc_number or "",
            },
            "payer_lines":  self._amacheck_address_lines(company),
            "payee_lines":  self._amacheck_address_lines(vendor),
            "from_address": self._amacheck_address(company),
            "to_address":   self._amacheck_address(vendor, with_company=True),
        }

    def _amacheck_client_ref(self):
        """Stable per-payment key so AMAChecks never mails the same payment twice."""
        self.ensure_one()
        db_uuid = self.env["ir.config_parameter"].sudo().get_param("database.uuid") or self.env.cr.dbname
        return "%s:%s" % (db_uuid, self.id)

    # ------------------------------------------------------------------
    # Send
    # ------------------------------------------------------------------

    def _amacheck_fail(self, message, inactive=False):
        self.write({
            "amacheck_state":    "failed",
            "amacheck_error":    message,
            "amacheck_inactive": inactive,
        })

    def action_send_amacheck(self):
        params       = self.env["ir.config_parameter"].sudo()
        license_code = (params.get_param("account_amacheck.license_code") or "").strip()
        if not license_code:
            raise UserError(
                "AMAChecks License Code is not configured. Go to Settings > AMACheck, "
                "enter your license code and click Refresh Balance."
            )

        already_sent = self.filtered(lambda p: p.amacheck_state == "sent")
        if already_sent:
            raise UserError(
                "These payments were already sent and can't be sent again: %s"
                % ", ".join(p.name or str(p.id) for p in already_sent)
            )

        for payment in self:
            if payment.payment_type != "outbound":
                payment._amacheck_fail("AMACheck only supports outbound payments.")
                continue
            if payment.partner_type != "supplier":
                payment._amacheck_fail("AMACheck only supports vendor payments.")
                continue
            if payment.amount <= 0:
                payment._amacheck_fail("Payment amount must be greater than zero.")
                continue
            if not payment.partner_id:
                payment._amacheck_fail("Payment is missing a vendor.")
                continue

            try:
                payment._amacheck_check_partner_address(payment.company_id.partner_id, "Your company")
                payment._amacheck_check_partner_address(payment.partner_id, "Vendor")
                journal = payment._amacheck_get_bank_journal()
                if not journal.amacheck_next_check_no:
                    journal.amacheck_next_check_no = 10000
                check = payment._amacheck_check_payload(journal)
            except UserError as e:
                payment._amacheck_fail(str(e.args[0] if e.args else e))
                continue

            try:
                result = amacheck_send_check(license_code, payment._amacheck_client_ref(), check)
            except AMACheckError as e:
                # AMAChecks never answered. Retrying is safe: the server
                # recognises this payment and will not mail it twice. The check
                # number may have been used, so don't give it to the next check.
                journal.amacheck_next_check_no = check["number"] + 1
                payment._amacheck_fail(
                    "%s\n\nThe check may or may not have been sent. It is safe to click "
                    "Send Check again — AMAChecks will not mail the same payment twice." % e
                )
                self.env.cr.commit()
                continue

            if result.get("checksLeft") is not None:
                params.set_param("account_amacheck.checks_left", str(result["checksLeft"]))

            if result.get("success"):
                payment.write({
                    "amacheck_state":        "sent",
                    "amacheck_zil_id":       result.get("checkId") or False,
                    "amacheck_check_number": result.get("checkNumber") or str(check["number"]),
                    "amacheck_sent_at":      fields.Datetime.now(),
                    "amacheck_error":        (
                        "Sandbox mode: this check was NOT mailed." if result.get("sandbox") else False
                    ),
                    "amacheck_inactive":     False,
                })
                if not result.get("duplicate"):
                    journal.amacheck_next_check_no = check["number"] + 1

            else:
                code    = result.get("code") or "error"
                message = result.get("error") or "Check send failed."
                if code == "unconfirmed":
                    # It may have been mailed with this number; don't reuse it.
                    journal.amacheck_next_check_no = check["number"] + 1
                    payment.write({
                        "amacheck_state":    "unconfirmed",
                        "amacheck_error":    message,
                        "amacheck_inactive": False,
                    })
                else:
                    payment._amacheck_fail(message, inactive=(code == "inactive"))

            # A check may have been mailed: save its state and the journal's next
            # check number now, so a later error in this batch can't roll them back.
            self.env.cr.commit()

        return True
