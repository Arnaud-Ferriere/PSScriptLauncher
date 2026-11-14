# AST analysis: warnings and errors attached to a script, labels of the parameter constraints,
# and arguments of an example that the form cannot reuse.
@{
    # Warnings added to a script, shown in the tree and in the detail pane.
    'analysis.warning.readFailed'                   = 'Cannot read: {0}'
    'analysis.warning.parseError'                   = 'Syntax error on line {0}: {1}'
    'analysis.warning.moreParseError'               = '... and {0} more syntax error(s).'
    'analysis.warning.misplacedHelp'                = 'Help is displayed, but Get-Help does not see it (help block in the wrong place).'
    'analysis.warning.misplacedHelpGlued'           = 'Help is displayed, but Get-Help does not see it: a blank line is missing between "{0}" and the help block.'
    'analysis.warning.misplacedHelpAfterUsing'      = 'Help is displayed, but Get-Help does not see it: the help block must come before the using statements.'
    'analysis.warning.misplacedHelpOnFunction'      = 'Get-Help attaches this help to the function {0}, which follows it. If this is the help of the script, leave two blank lines between the help block and the function.'
    'analysis.warning.dynamicParam'                 = 'DynamicParam block: dynamic parameters are not displayed.'
    # The path given to the inventory is not a folder.
    'analysis.error.notFolder'                      = 'The path given is not a folder: {0}'
    # Labels of the constraints of a parameter (parameter form and help text).
    'analysis.validation.range'                     = 'Range: {0} to {1}'
    'analysis.validation.bound'                     = 'Value {0} {1}'
    'analysis.validation.pattern'                   = 'Pattern: {0}'
    # Arguments read from an example that the form cannot reuse.
    'analysis.example.unnamed'                      = '{0} (unnamed argument)'
    'analysis.example.unknownParameter'             = '-{0} (parameter unknown to the form)'
    'analysis.warning.unknownHelpSection' = 'Help block ignored by Get-Help: unknown section(s) {0}. Remove or rename them.'
}
