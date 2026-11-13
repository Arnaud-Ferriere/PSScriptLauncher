# Analyse par AST : avertissements et erreurs rattachés à un script, libellés des contraintes
# d'un paramètre, et arguments d'un exemple que le formulaire ne peut pas réutiliser.
@{
    # Avertissements rattachés à un script, affichés dans l'arborescence et le volet de détail.
    'analysis.warning.readFailed'                   = 'Lecture impossible : {0}'
    'analysis.warning.parseError'                   = 'Erreur de syntaxe ligne {0} : {1}'
    'analysis.warning.moreParseError'               = '... et {0} autre(s) erreur(s) de syntaxe.'
    'analysis.warning.misplacedHelp'                = "Aide affichée, mais Get-Help ne la voit pas (bloc d'aide mal placé)."
    'analysis.warning.misplacedHelpGlued'           = "Aide affichée, mais Get-Help ne la voit pas : il manque une ligne vide entre « {0} » et le bloc d'aide."
    'analysis.warning.misplacedHelpAfterUsing'      = "Aide affichée, mais Get-Help ne la voit pas : le bloc d'aide doit précéder les instructions using."
    'analysis.warning.misplacedHelpOnFunction'      = "Get-Help rattache cette aide à la fonction {0}, qui la suit. Si c'est l'aide du script, laissez deux lignes vides entre le bloc d'aide et la fonction."
    'analysis.warning.dynamicParam'                 = 'Bloc DynamicParam : les paramètres dynamiques ne sont pas affichés.'
    # Le chemin donné à l'inventaire n'est pas un dossier.
    'analysis.error.notFolder'                      = "Le chemin indiqué n'est pas un dossier : {0}"
    # Libellés des contraintes d'un paramètre (formulaire du paramètre et texte d'aide).
    'analysis.validation.range'                     = 'Intervalle : {0} à {1}'
    'analysis.validation.bound'                     = 'Valeur {0} {1}'
    'analysis.validation.pattern'                   = 'Motif : {0}'
    # Arguments lus dans un exemple que le formulaire ne peut pas réutiliser.
    'analysis.example.unnamed'                      = '{0} (argument sans nom)'
    'analysis.example.unknownParameter'             = '-{0} (paramètre inconnu du formulaire)'
}
