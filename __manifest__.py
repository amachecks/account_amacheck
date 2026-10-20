{
    "name": "AMACheck",
    "version": "19.0.1.2.0",
    "summary": "Mail vendor checks from Odoo payments with AMAChecks",
    "description": """
Mail vendor payments as printed checks through AMAChecks.

Features:
- One-click Send Check from a vendor payment
- Prepaid eCheck balance, checked on every send
- Duplicate protection: the same payment is never mailed twice
- Transaction log with live mail status
    """,
    "author": "AMA Systems",
    "website": "https://www.amachecks.com",
    "category": "Accounting/Payment",
    "license": "OPL-1",
    "application": True,
    "depends": ["account", "mail"],
    "data": [
        "security/ir.model.access.csv",
        "views/amacheck_transaction_views.xml",
        "views/res_config_settings_views.xml",
        "views/account_payment_views.xml",
        "views/account_journal_views.xml",
    ],
    "images": ["static/description/banner.png"],
    "installable": True,
}
