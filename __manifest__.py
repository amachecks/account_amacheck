{
    "name": "AMACheck",
    "version": "1.0",
    "depends": ["account", "mail"],
    "data": [
	'views/res_config_settings_views.xml',
        "security/ir.model.access.csv",
        "views/account_payment_views.xml",
	"views/res_config_settings_views.xml",
	"views/account_journal_views.xml",
    ],
    "installable": True,
}
