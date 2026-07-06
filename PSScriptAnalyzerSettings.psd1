@{
    # Run PowerShell's full built-in default rule set. PSAvoidUsingPlainTextForPassword and
    # PSAvoidUsingConvertToSecureStringWithPlainText are both already part of that default set
    # and are deliberately left enabled here (never excluded) because they catch real,
    # security-relevant findings in this codebase. The handful of places where the deployment
    # design genuinely requires plaintext password handling (autologon re-arming, WLAN profile
    # XML, .env secret plumbing, building a credential for New-LocalUser) are suppressed only at
    # the specific offending function/parameter with an inline
    # [Diagnostics.CodeAnalysis.SuppressMessage(...)] attribute and a one-line justification -
    # never blanket-suppressed here.
    IncludeDefaultRules = $true

    ExcludeRules        = @(
        # This toolkit is an unattended deployment orchestrator, not a general-purpose module of
        # reusable cmdlets: functions named New-/Set-/Remove-/Stop- etc. that "change system
        # state" here are internal deployment steps that already have their own
        # confirmation/resume flow (deployment_state.json, Request-DeploymentReboot, the
        # Start/Resume-Deployment.ps1 prompts) rather than being general-purpose cmdlets a
        # caller would expect to drive with -WhatIf/-Confirm. Adding SupportsShouldProcess to
        # every such function across the codebase would be pure ceremony with no caller ever
        # passing -WhatIf/-Confirm and no real safety benefit.
        'PSUseShouldProcessForStateChangingFunctions',

        # Function nouns here are established, cross-file deployment-domain concepts
        # (DeploymentSteps, DeploymentPaths, InstalledProgramNames, LocalUserDefinitions, ...)
        # that are already dot-sourced and called from many other scripts in this repo. Renaming
        # them to satisfy this purely cosmetic rule is out of scope for a lint-fix pass (no
        # behavioural/API changes) since it would ripple across every call site for zero
        # behavioural benefit.
        'PSUseSingularNouns'
    )
}
