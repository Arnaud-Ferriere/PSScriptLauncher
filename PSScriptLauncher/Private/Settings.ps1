# Réglages du lanceur. Chargé en premier : les autres fichiers lisent $script:Settings.

$script:ModuleRoot = Split-Path -Parent $PSScriptRoot

$script:Settings = @{
    AutoExpandLimit      = 40        # au-delà de ce nombre de scripts, l'arborescence s'ouvre repliée
    SearchDelayMs        = 250       # temporisation de la recherche pendant la frappe
    ScanPollMs           = 150       # fréquence de rafraîchissement de la progression de l'inventaire
    MaxParseErrorShown   = 3         # erreurs de syntaxe détaillées par script
    MaxEchoLength        = 600       # au-delà, la commande rappelée dans la console est tronquée
    MaxCommandLineLength = 32000     # Windows refuse une ligne de commande de plus de 32 767 caractères
    MaxRecent            = 8         # scripts conservés dans « Récents »
    MaxRememberedScript  = 300       # scripts dont la dernière saisie est conservée
    MaxExampleLabel      = 90        # longueur du libellé d'un exemple dans la liste
}
