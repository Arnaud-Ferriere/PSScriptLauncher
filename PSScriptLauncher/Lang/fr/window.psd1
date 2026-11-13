# Fenêtre : barre d'état, arborescence, dialogues, erreurs visibles par l'utilisateur.
@{
    'window.status.scanning'      = 'Analyse des scripts...'
    'window.status.scanningOf'    = 'Analyse des scripts... {0} / {1}'
    'window.status.catalog'       = '{0} script(s) · {1:N1} s'
    'window.status.warnings'      = '{0} avec avertissement'
    'window.status.errors'        = '{0} élément(s) illisible(s)'
    'window.status.folderShown'   = 'Ce dossier est déjà affiché.'
    'window.status.scriptLaunched' = 'Lancé : {0} ({1})'
    'window.status.commandCopied' = 'Commande copiée dans le presse-papiers.'
    'window.status.inputCleared'  = 'Saisie effacée.'
    'window.status.inputRestored' = "Dernière saisie restaurée (« Effacer la saisie » pour repartir de zéro)."
    'window.section.favorites'    = '★ Favoris'
    'window.section.recents'      = 'Récents'
    'window.tree.noScript'        = 'Aucun script trouvé.'
    'window.tree.noMatch'         = 'Aucun script ne correspond.'
    'window.detail.noHelp'        = "Aucune aide (comment-based help) trouvée dans ce script."
    'window.detail.noParameter'   = 'Ce script ne déclare aucun paramètre.'
    'window.error.startup'        = "Le lanceur n'a pas pu démarrer : {0}"
    'window.error.folderNotFound' = 'Dossier introuvable : {0}'
    'window.error.scanFailed'     = "Échec de l'analyse : {0}"
    'window.error.catalogEmpty'   = "l'inventaire n'a renvoyé aucun résultat."
    'window.error.uiElement'      = "Élément d'interface introuvable : {0}"
    'window.error.needsWindows'   = 'Ce lanceur utilise WPF : il ne fonctionne que sous Windows.'
    'window.error.needsFullLanguage' = 'Mode de langage {0} : WPF exige FullLanguage (stratégie AppLocker/WDAC ?).'
    'window.error.needsSta'       = 'WPF exige un thread STA. Relancez avec : powershell.exe -STA -File "{0}"'
    'window.dialog.pickFolder'    = 'Choisir un dossier'
    # Dialogues et messages du lancement.
    'window.error.preferences'    = 'Préférences non enregistrées : {0}'
    'window.favorite.add'         = 'Ajouter à mes favoris'
    'window.favorite.remove'      = 'Retirer de mes favoris'
    'window.example.placeholder'  = '(remplir depuis un exemple)'
    'window.example.applied'      = 'Exemple {0} appliqué.'
    'window.example.toEnter'      = '-{0} {1} (à saisir)'
    'window.example.ignored'      = 'Non repris : {0}'
    'window.confirm.title'        = 'Vérification'
    'window.confirm.missing'      = 'Paramètres obligatoires non renseignés : {0}'
    'window.confirm.willAsk'      = '(PowerShell les demandera dans la console.)'
    'window.confirm.runAnyway'    = 'Lancer quand même ?'
    'window.error.commandTooLong' = 'La commande est trop longue pour être lancée ({0} caractères, limite de Windows : {1}). Réduisez les valeurs saisies, ou copiez la commande et exécutez-la dans une console.'
    'window.error.noEngine'       = 'Aucun moteur PowerShell disponible.'
    'window.status.elevationCancelled' = 'Élévation annulée.'
    'window.error.coreRequired' = 'Ce script exige PowerShell 7+, introuvable sur ce poste (pwsh.exe).'
    'window.tree.noHelp'         = 'Aucune aide'
    'window.error.uiAction'       = 'Erreur : {0}'
}
