{
    "name": "AMACheck",
    "version": "19.0.1.1.0",
    "summary": "Send vendor checks by mail via AMACheck / Online Check Writer",
    "description": """
Send vendor payments as physical checks via the AMACheck (Online Check Writer) API.

Features:
- Sandbox and Production environment toggle
- Automatic payee sync to AMACheck
- Automatic bank account sync to AMACheck
- Duplicate send protection
- Detailed error reporting
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
